#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
#include "swift/Runtime/HeapObject.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <mutex>
#include <objc/runtime.h>
#include <objc/message.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <dlfcn.h>

using namespace swift;

static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();
static void ensureTrackingInitialized();

// Helper functions for CSV handling
static const char* getStatsPath() {
  static char cachedPath[512] = {0};
  static bool initialized = false;
  
  if (!initialized) {
    const char *dir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
    if (dir && strlen(dir) > 0) {
      snprintf(cachedPath, sizeof(cachedPath), "%s/swift_class_lifecycle_stats.csv", dir);
    } else {
      snprintf(cachedPath, sizeof(cachedPath), "swift_class_lifecycle_stats.csv");
    }
    initialized = true;
  }
  
  return cachedPath;
}

static void writeCSVToFile(std::ofstream& file, const std::unordered_map<std::string, ClassLifecycleStats>& statsMap) {
  // Write header
  file << "ClassName,InitCount,DeinitCount\n";
  
  // Write all tracked classes (even with 0,0 to preserve tracking state)
  for (const auto& entry : statsMap) {
    file << entry.first << ',' << entry.second.initCount << ',' << entry.second.deinitCount << '\n';
  }
}

static bool parseCSVStats(const std::string& filePath, std::unordered_map<std::string, ClassLifecycleStats>& stats) {
  std::ifstream file(filePath);
  if (!file.is_open()) return false;
  
  std::string line;
  std::getline(file, line); // Skip header
  
  while (std::getline(file, line)) {
    size_t comma1 = line.find(',');
    size_t comma2 = line.find(',', comma1 + 1);
    if (comma1 == std::string::npos || comma2 == std::string::npos) continue;
    
    // Parse numbers directly without creating substrings
    char* endPtr = nullptr;
    const char* lineData = line.c_str();
    
    unsigned long initCount = std::strtoul(lineData + comma1 + 1, &endPtr, 10);
    if (endPtr == lineData + comma1 + 1) continue; // Parse error
    
    unsigned long deinitCount = std::strtoul(lineData + comma2 + 1, &endPtr, 10);
    if (endPtr == lineData + comma2 + 1) continue; // Parse error
    
    // Only create string for the class name
    ClassLifecycleStats stat;
    stat.initCount = initCount;
    stat.deinitCount = deinitCount;
    stats[line.substr(0, comma1)] = stat;
  }
  return true;
}

namespace {
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
} // namespace

// iOS Simulator termination handler (UITest scenarios)
static void setupAppTerminationHandler() {
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
  // Schedule on main queue to ensure UIApplication is available
  dispatch_async(dispatch_get_main_queue(), ^{
    Class NSNotificationCenterClass = objc_getClass("NSNotificationCenter");
    if (!NSNotificationCenterClass) {
      fprintf(stderr, "[YSWIFT] NSNotificationCenter not available\n");
      return;
    }
    
    SEL defaultCenterSel = sel_registerName("defaultCenter");
    id (*defaultCenterImp)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    id center = defaultCenterImp(NSNotificationCenterClass, defaultCenterSel);
    
    if (!center) {
      fprintf(stderr, "[YSWIFT] Failed to get NSNotificationCenter defaultCenter\n");
      return;
    }
    
    // Create NSString notification names using runtime APIs
    Class NSStringClass = objc_getClass("NSString");
    SEL stringWithUTF8Sel = sel_registerName("stringWithUTF8String:");
    id (*stringWithUTF8Imp)(Class, SEL, const char*) = (id (*)(Class, SEL, const char*))objc_msgSend;
    
    id terminateNotificationName = stringWithUTF8Imp(NSStringClass, stringWithUTF8Sel, "UIApplicationWillTerminateNotification");
    id backgroundNotificationName = stringWithUTF8Imp(NSStringClass, stringWithUTF8Sel, "UIApplicationDidEnterBackgroundNotification");
    
    // Register observers using blocks
    typedef void (^NotificationBlock)(id notification);
    
    NotificationBlock terminateBlock = ^(id notification) {
      fprintf(stderr, "[YSWIFT] *** UIApplication will terminate, writing stats ***\n");
      writeClassLifecycleStatisticsNow();
    };
    
    NotificationBlock backgroundBlock = ^(id notification) {
      fprintf(stderr, "[YSWIFT] *** UIApplication entered background, writing stats ***\n");
      writeClassLifecycleStatisticsNow();
    };
    
    SEL addObserverSel = sel_registerName("addObserverForName:object:queue:usingBlock:");
    id (*addObserverImp)(id, SEL, id, id, id, id) = (id (*)(id, SEL, id, id, id, id))objc_msgSend;
    
    // Register for terminate notification
    addObserverImp(center, addObserverSel, terminateNotificationName, nil, nil, terminateBlock);
    
    // Register for background notification  
    addObserverImp(center, addObserverSel, backgroundNotificationName, nil, nil, backgroundBlock);
    
    fprintf(stderr, "[YSWIFT] iOS Simulator lifecycle handlers registered (terminate + background)\n");
  });
#else
  // Not running on iOS Simulator - no handlers registered
  fprintf(stderr, "[YSWIFT] Not on iOS Simulator - no termination handlers registered\n");
#endif
}

static void initializeTracking() {
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
  fprintf(stderr, "[YSWIFT] Initializing tracking on iOS Simulator\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();

  fprintf(stderr, "[YSWIFT] Enumerating all classes in target...\n");
  enumerateAllClassesInTarget();

  // Register iOS Simulator termination handler (UITest scenarios)
  setupAppTerminationHandler();
  
  fprintf(stderr, "[YSWIFT] iOS Simulator: UIApplication notification handlers active\n");
#else
  // Not on iOS Simulator - initialize but no handlers
  fprintf(stderr, "[YSWIFT] Not on iOS Simulator - tracking disabled\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();
#endif
}

void swift::logClassLifecycle(const HeapObject *object, const char *event) {
  // Fast path: early exits
  if (!object || !event) return;
  
  // Fast path: check initialization without function call overhead
  if (!trackingInitialized.load(std::memory_order_acquire)) {
    ensureTrackingInitialized();
  }
  
  const HeapMetadata *metadata = object->metadata;
  if (!metadata || metadata->getKind() != MetadataKind::Class) return;
  
  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty() || !classStatsMap) return;

  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    
    // Early exit if class not tracked
    auto it = classStatsMap->find(qualifiedName);
    if (it == classStatsMap->end()) {
      return;
    }

    // Update stats - branchless comparison
    it->second.initCount += (event[0] == 'I');
    it->second.deinitCount += (event[0] == 'D');
  }
}

// Alternative initialization check - called separately if needed
static void ensureTrackingInitialized() {
  if (!trackingInitialized.load(std::memory_order_acquire)) {
    static std::once_flag initFlag;
    std::call_once(initFlag, []() {
      trackingInitialized.store(true, std::memory_order_release);
      initializeTracking();
    });
  }
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
static void writeClassLifecycleStatisticsNow() {
#else
static void writeClassLifecycleStatisticsNow() __attribute__((unused));
static void writeClassLifecycleStatisticsNow() {
#endif
  if (!trackingInitialized.load(std::memory_order_acquire)) return;
  if (!classStatsMap || !classStatsMapMutex) return;

  // Copy data under lock, write to file without lock
  std::unordered_map<std::string, ClassLifecycleStats> statsCopy;
  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    statsCopy = *classStatsMap;
  }

  // Write to file outside of mutex lock
  const char* path = getStatsPath();
  std::ofstream file(path, std::ios::out | std::ios::trunc);
  if (file.is_open()) {
    writeCSVToFile(file, statsCopy);
    fprintf(stderr, "[YSWIFT] Stats written to: %s (%zu classes)\n", path, statsCopy.size());
  } else {
    fprintf(stderr, "[YSWIFT] Failed to write: %s\n", path);
  }
}

static bool isAppImageName(const char* imageName) {
  if (!imageName) return false;
  
  // Cache the app name and pattern
  static const char *appName = getenv("SWIFT_APP_NAME");
  static char pattern[256];
  static size_t patternLen = 0;
  static bool patternInitialized = false;
  static bool hasAppName = false;
  
  if (!patternInitialized) {
    hasAppName = (appName != nullptr && appName[0] != '\0');
    if (hasAppName) {
      patternLen = snprintf(pattern, sizeof(pattern), "%s.app/", appName);
    }
    patternInitialized = true;
  }
  
  // Early exit if no app name configured
  if (!hasAppName) return false;
  
  // Quick length check before strstr
  size_t imageLen = strlen(imageName);
  if (imageLen < patternLen) return false;
  
  // Use strstr once and cache result
  const char *appLocation = strstr(imageName, pattern);
  if (!appLocation) return false;
  
  // Check if it's not in Frameworks (strstr is expensive, do it only if needed)
  return !strstr(imageName, "/Frameworks/");
}

static bool isAppClass(Class cls, const std::unordered_set<const char*>& appImages) {
  if (!cls) return false;
  
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;
  
  // Fast lookup in pre-filtered app images set
  return appImages.find(imageName) != appImages.end();
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
static void enumerateAllClassesInTarget() {
#else
static void enumerateAllClassesInTarget() __attribute__((unused));
static void enumerateAllClassesInTarget() {
#endif
  if (!classStatsMap || !classStatsMapMutex)
    return;

  // Step 1: Get all classes
  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);
  
  if (!classes) {
    fprintf(stderr, "[YSWIFT] No classes found\n");
    return;
  }
  
  fprintf(stderr, "[YSWIFT] Total classes to scan: %u\n", numClasses);
  
  // Step 2: Build a set of unique image names (much smaller than class count)
  std::unordered_set<const char*> uniqueImages;
  uniqueImages.reserve(256); // Most apps have < 100 images
  
  for (unsigned int i = 0; i < numClasses; i++) {
    const char *imageName = class_getImageName(classes[i]);
    if (imageName) {
      uniqueImages.insert(imageName);
    }
  }
  
  fprintf(stderr, "[YSWIFT] Found %zu unique images\n", uniqueImages.size());
  
  // Step 3: Filter to app images only (this is where the expensive string operations happen)
  std::unordered_set<const char*> appImages;
  appImages.reserve(32); // App images are typically very few
  
  for (const char* imageName : uniqueImages) {
    if (isAppImageName(imageName)) {
      appImages.insert(imageName);
    }
  }
  
  fprintf(stderr, "[YSWIFT] Filtered to %zu app images\n", appImages.size());
  
  // If no app images found, bail early
  if (appImages.empty()) {
    free(classes);
    fprintf(stderr, "[YSWIFT] No app images found, skipping class enumeration\n");
    return;
  }
  
  // Step 4: Filter classes by app images (fast pointer comparison)
  std::vector<const char*> appClassNames;
  appClassNames.reserve(numClasses / 10); // Better estimate for large apps
  
  for (unsigned int i = 0; i < numClasses; i++) {
    if (!isAppClass(classes[i], appImages)) continue;
    const char *className = class_getName(classes[i]);
    if (className) {
      appClassNames.push_back(className);
    }
  }
  
  free(classes); // Free early, we're done with the class list
  
  fprintf(stderr, "[YSWIFT] Filtered to %zu app classes\n", appClassNames.size());
  
  // Step 5: Load existing stats (outside lock)
  std::unordered_map<std::string, ClassLifecycleStats> existingStats;
  existingStats.reserve(appClassNames.size());
  parseCSVStats(getStatsPath(), existingStats);
  
  // Step 6: Populate stats map under lock (minimize lock time)
  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    classStatsMap->reserve(appClassNames.size());
    
    for (const char* className : appClassNames) {
      std::string classNameStr(className);
      
      // Check if we have existing stats for this class
      auto existingIt = existingStats.find(classNameStr);
      if (existingIt != existingStats.end()) {
        (*classStatsMap)[std::move(classNameStr)] = existingIt->second;
      } else {
        // New class, initialize with 0,0
        (*classStatsMap)[std::move(classNameStr)] = ClassLifecycleStats();
      }
    }
    
    fprintf(stderr, "[YSWIFT] Loaded %zu app classes into tracking map\n", classStatsMap->size());
  }
}

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
#include <vector>

using namespace swift;

static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();
static void ensureTrackingInitialized();

static const char* getStatsPath() {
  static char path[512] = {0};
  if (!path[0]) {
    const char *dir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
    snprintf(path, sizeof(path), "%s%sswift_class_lifecycle_stats.csv", 
             dir && dir[0] ? dir : "", dir && dir[0] ? "/" : "");
  }
  return path;
}

static void parseCSVStats(const char* filePath, std::unordered_map<std::string, ClassLifecycleStats>& stats) {
  std::ifstream file(filePath);
  if (!file.is_open()) return;
  
  std::string line;
  std::getline(file, line); // Skip header
  
  while (std::getline(file, line)) {
    size_t c1 = line.find(','), c2 = line.find(',', c1 + 1);
    if (c1 == std::string::npos || c2 == std::string::npos) continue;
    
    ClassLifecycleStats stat;
    stat.initCount = std::strtoul(line.c_str() + c1 + 1, nullptr, 10);
    stat.deinitCount = std::strtoul(line.c_str() + c2 + 1, nullptr, 10);
    stats[line.substr(0, c1)] = stat;
  }
}

namespace {
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
} // namespace

static void setupAppTerminationHandler() {
  dispatch_async(dispatch_get_main_queue(), ^{
    id center = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"));
    if (!center) return;
    
    auto makeString = [](const char* str) -> id {
      return ((id (*)(Class, SEL, const char*))objc_msgSend)(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), str);
    };
    
    auto addObserver = [&](const char* name) {
      ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(center, sel_registerName("addObserverForName:object:queue:usingBlock:"), 
        makeString(name), nil, nil, ^(id _) { writeClassLifecycleStatisticsNow(); });
    };
    
    addObserver("UIApplicationWillTerminateNotification");
    addObserver("UIApplicationDidEnterBackgroundNotification");
  });
}

static void initializeTracking() {
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();
  enumerateAllClassesInTarget();
  setupAppTerminationHandler();
  fprintf(stderr, "[YSWIFT] Tracking initialized\n");
}

void swift::logClassLifecycle(const HeapObject *object, const char *event) {
  if (!object || !event) return;
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

static void ensureTrackingInitialized() {
  static std::once_flag initFlag;
  std::call_once(initFlag, []() {
    trackingInitialized.store(true, std::memory_order_release);
    initializeTracking();
  });
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
  std::ofstream file(getStatsPath(), std::ios::out | std::ios::trunc);
  if (file.is_open()) {
    file << "ClassName,InitCount,DeinitCount\n";
    for (const auto& entry : statsCopy) {
      file << entry.first << ',' << entry.second.initCount << ',' << entry.second.deinitCount << '\n';
    }
    fprintf(stderr, "[YSWIFT] Stats written to: %s (%zu classes)\n", getStatsPath(), statsCopy.size());
  } else {
    fprintf(stderr, "[YSWIFT] Failed to write: %s\n", getStatsPath());
  }
}

static bool isAppClass(Class cls) {
  if (!cls) return false;
  
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;
  
  // Cache main executable path
  static char mainExecPath[512];
  static bool pathInitialized = false;
  
  if (!pathInitialized) {
    const char *appName = getenv("SWIFT_APP_NAME");
    if (appName && appName[0] != '\0') {
      snprintf(mainExecPath, sizeof(mainExecPath), "%s.app/%s", appName, appName);
    } else {
      mainExecPath[0] = '\0';
    }
    pathInitialized = true;
  }
  
  if (mainExecPath[0] == '\0') return false;
  
  return strstr(imageName, mainExecPath) && !strstr(imageName, "/Frameworks/");
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
static void enumerateAllClassesInTarget() {
#else
static void enumerateAllClassesInTarget() __attribute__((unused));
static void enumerateAllClassesInTarget() {
#endif
  if (!classStatsMap || !classStatsMapMutex) return;

  const char *discoverMode = getenv("RUNTIME_DISCOVER");
  const char *classListPath = getenv("RUNTIME_DISCOVER_RESULT");
  bool shouldDiscover = discoverMode && strcmp(discoverMode, "true") == 0;
  
  std::vector<std::string> appClassNames;
  
  if (classListPath) {
    if (shouldDiscover) {
      unsigned int numClasses = 0;
      Class *classes = objc_copyClassList(&numClasses);
      if (classes) {
        for (unsigned int i = 0; i < numClasses; i++) {
          if (isAppClass(classes[i])) {
            const char *name = class_getName(classes[i]);
            if (name) appClassNames.push_back(name);
          }
        }
        free(classes);
        
        std::ofstream file(classListPath);
        for (const auto& name : appClassNames) file << name << '\n';
        fprintf(stderr, "[YSWIFT] Discovered %zu classes written to: %s\n", appClassNames.size(), classListPath);
      }
    } else {
      std::ifstream file(classListPath);
      std::string line;
      while (std::getline(file, line)) {
        if (!line.empty()) appClassNames.push_back(line);
      }
      fprintf(stderr, "[YSWIFT] Loaded %zu classes from: %s\n", appClassNames.size(), classListPath);
    }
  }
  
  // Load existing stats and populate tracking map
  std::unordered_map<std::string, ClassLifecycleStats> existingStats;
  parseCSVStats(getStatsPath(), existingStats);
  
  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  classStatsMap->reserve(appClassNames.size());
  for (auto& name : appClassNames) {
    auto it = existingStats.find(name);
    (*classStatsMap)[name] = it != existingStats.end() ? it->second : ClassLifecycleStats();
  }
}

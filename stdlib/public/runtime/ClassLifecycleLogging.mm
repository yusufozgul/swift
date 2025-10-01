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
#include <signal.h>
#include <unistd.h>
#include <unordered_map>

#ifdef __OBJC__
  #import <Foundation/Foundation.h>
  #import <UIKit/UIKit.h>
#endif

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

// Signal handler for graceful shutdown
// Note: writeClassLifecycleStatisticsNow uses mutex which is NOT async-signal-safe,
// but in practice this works for termination signals where we're exiting anyway
static void signalHandler(int signum) {
  // Minimal signal-safe logging
  const char msg[] = "[YSWIFT] *** Signal received, writing stats ***\n";
  write(STDERR_FILENO, msg, sizeof(msg) - 1);
  
  writeClassLifecycleStatisticsNow();
  
  // Re-raise signal to continue default handling
  signal(signum, SIG_DFL);
  raise(signum);
}

// iOS UIApplication termination handler
static void setupiOSTerminationHandler() {
#if TARGET_OS_IPHONE && defined(__OBJC__)
  // Schedule on main queue to ensure UIApplication is available
  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
      
      // Register for UIApplicationWillTerminateNotification (normal app termination)
      [center addObserverForName:UIApplicationWillTerminateNotification
        object:nil
        queue:nil
        usingBlock:^(NSNotification *notification) {
          fprintf(stderr, "[YSWIFT] *** UIApplication will terminate, writing stats ***\n");
          writeClassLifecycleStatisticsNow();
        }];
      
      // Register for UIApplicationDidEnterBackgroundNotification (UITest often suspends)
      [center addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil
        queue:nil
        usingBlock:^(NSNotification *notification) {
          fprintf(stderr, "[YSWIFT] *** UIApplication entered background, writing stats ***\n");
          writeClassLifecycleStatisticsNow();
        }];
      
      fprintf(stderr, "[YSWIFT] iOS lifecycle handlers registered (terminate + background)\n");
    }
  });
#else
  // Fallback: rely on signal handlers only
  fprintf(stderr, "[YSWIFT] iOS termination handler not available (compile as .mm for UIApplication support)\n");
#endif
}

static void initializeTracking() {
  fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();

  fprintf(stderr, "[YSWIFT] Enumerating all classes in iOS Simulator target...\n");
  enumerateAllClassesInTarget();

  // Register signal handlers for graceful shutdown (Unix signals)
  signal(SIGTERM, signalHandler);
  signal(SIGINT, signalHandler);
  signal(SIGQUIT, signalHandler);
  fprintf(stderr, "[YSWIFT] Signal handlers registered\n");
  
  // Register iOS-specific termination handler (for UITest scenarios)
  setupiOSTerminationHandler();
  
  fprintf(stderr, "[YSWIFT] Termination handlers registered. Stats will be written on program termination.\n");
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

static void writeClassLifecycleStatisticsNow() {
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

static bool isAppClass(Class cls) {
  if (!cls) return false;
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;
  
  // Cache the app name and pattern
  static const char *appName = getenv("SWIFT_APP_NAME");
  static char pattern[256];
  static bool patternInitialized = false;
  
  if (!patternInitialized) {
    snprintf(pattern, sizeof(pattern), "%s.app/", appName);
    patternInitialized = true;
  }
  
  return strstr(imageName, pattern) && !strstr(imageName, "/Frameworks/");
}

static void enumerateAllClassesInTarget() {
  if (!classStatsMap || !classStatsMapMutex)
    return;

  // Load existing stats first (outside lock)
  std::unordered_map<std::string, ClassLifecycleStats> existingStats;
  existingStats.reserve(1024); // Pre-allocate for better performance
  parseCSVStats(getStatsPath(), existingStats);

  // Enumerate all app classes
  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);
  
  if (!classes) {
    fprintf(stderr, "[YSWIFT] No classes found\n");
    return;
  }
  
  // Process classes under lock
  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    classStatsMap->reserve(numClasses / 10); // Estimate ~10% are app classes
    
    for (unsigned int i = 0; i < numClasses; i++) {
      const char *className = class_getName(classes[i]);
      if (!className || !isAppClass(classes[i])) continue;
      
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
    
    fprintf(stderr, "[YSWIFT] Found %zu app classes\n", classStatsMap->size());
  }
  
  free(classes);
}

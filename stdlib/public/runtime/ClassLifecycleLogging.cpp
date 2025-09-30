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
#include <unordered_map>

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
  file << "ClassName,InitCount,DeinitCount\n";
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

static void initializeTracking() {
  fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();

  fprintf(stderr, "[YSWIFT] Enumerating all classes in iOS Simulator target...\n");
  enumerateAllClassesInTarget();

  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, 
                                                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 
                           30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    fprintf(stderr, "[YSWIFT] *** Timer fired, writing stats ***\n");
    writeClassLifecycleStatisticsNow();
  });
  dispatch_resume(timer);
}

void swift::logClassLifecycle(const HeapObject *object, const char *event) {
  if (!object) return;
  
  const HeapMetadata *metadata = object->metadata;
  
  // Fast path: check initialization without function call overhead
  if (!trackingInitialized.load(std::memory_order_acquire)) {
    ensureTrackingInitialized();
  }
  
  if (metadata->getKind() != MetadataKind::Class) return;
  
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

    // Update stats - branchless increment where possible
    if (event[0] == 'I') { 
      it->second.initCount++; 
    } else if (event[0] == 'D') { 
      it->second.deinitCount++; 
    }
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
  if (!trackingInitialized.load()) return;
  if (!classStatsMap || !classStatsMapMutex) return;

  // Copy data under lock, write to file without lock
  std::unordered_map<std::string, ClassLifecycleStats> statsCopy;
  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    statsCopy = *classStatsMap;
  }

  // Write to file outside of mutex lock
  const char* path = getStatsPath();
  std::ofstream file(path);
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

  // Load existing stats first
  std::unordered_map<std::string, ClassLifecycleStats> existingStats;
  existingStats.reserve(1024); // Pre-allocate for better performance
  parseCSVStats(getStatsPath(), existingStats);

  // Enumerate all app classes
  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);
  
  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  
  if (classes) {
    for (unsigned int i = 0; i < numClasses; i++) {
      const char *className = class_getName(classes[i]);
      if (className && isAppClass(classes[i])) {
        std::string classNameStr(className);
        
        // Check if we have existing stats for this class
        auto existingIt = existingStats.find(classNameStr);
        if (existingIt != existingStats.end()) {
          (*classStatsMap)[classNameStr] = existingIt->second;
        } else {
          // New class, initialize with 0,0
          (*classStatsMap)[classNameStr] = ClassLifecycleStats();
        }
      }
    }
    free(classes);
  }
  
  fprintf(stderr, "[YSWIFT] Found %zu app classes\n", classStatsMap->size());
}

#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <mutex>
#include <objc/runtime.h>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

using namespace swift;

static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();
static void ensureTrackingInitialized();

// Helper functions for CSV handling
static std::string getStatsPath() {
  const char *dir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
  return dir && strlen(dir) > 0 ? std::string(dir) + "/swift_class_lifecycle_stats.csv" 
                                : "swift_class_lifecycle_stats.csv";
}

static std::string toCSV(const std::unordered_map<std::string, ClassLifecycleStats>& statsMap) {
  std::ostringstream csv;
  csv << "ClassName,InitCount,DeinitCount\n";
  for (const auto& entry : statsMap) {
    csv << entry.first << "," << entry.second.initCount << "," << entry.second.deinitCount << "\n";
  }
  return csv.str();
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
    
    try {
      stats[line.substr(0, comma1)] = {
        std::stoul(line.substr(comma1 + 1, comma2 - comma1 - 1)),
        std::stoul(line.substr(comma2 + 1))
      };
    } catch (...) {}
  }
  return true;
}

namespace {
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::unordered_set<std::string> *discoveredClasses = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
} // namespace

static void initializeTracking() {
  fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  discoveredClasses = new std::unordered_set<std::string>();
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

void swift::logClassLifecycle(const HeapMetadata *metadata, const char *event) {
  ensureTrackingInitialized();
  
  if (metadata->getKind() != MetadataKind::Class) return;
  
  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty() || !discoveredClasses) return;

  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    
    // Early exit if class not tracked
    if (discoveredClasses->find(qualifiedName) == discoveredClasses->end()) {
      return;
    }

    // Update stats
    auto &stats = (*classStatsMap)[qualifiedName];
    if (event[0] == 'I') { 
      stats.initCount++; 
    } else if (event[0] == 'D') { 
      stats.deinitCount++; 
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

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  if (classStatsMap->empty()) return;

  std::string path = getStatsPath();
  std::ofstream file(path);
  if (file.is_open()) {
    file << toCSV(*classStatsMap);
    fprintf(stderr, "[YSWIFT] Stats written to: %s\n", path.c_str());
  } else {
    fprintf(stderr, "[YSWIFT] Failed to write: %s\n", path.c_str());
  }
}

static bool isAppClass(Class cls) {
  if (!cls) return false;
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;
  static const char *appName = getenv("SWIFT_APP_NAME");
  char pattern[256];
  snprintf(pattern, sizeof(pattern), "%s.app/", appName);
  return strstr(imageName, pattern) && !strstr(imageName, "/Frameworks/");
}

static void enumerateAllClassesInTarget() {
  if (!classStatsMap || !classStatsMapMutex)
    return;

  std::unordered_set<std::string> discoveredClassesSet;
  discoveredClassesSet.reserve(1024);

  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);
  if (classes) {
    for (unsigned int i = 0; i < numClasses; i++) {
      const char *className = class_getName(classes[i]);
      if (className && isAppClass(classes[i])) {
        discoveredClassesSet.emplace(className);
      }
    }
    free(classes);
  }

  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    *discoveredClasses = discoveredClassesSet;
    fprintf(stderr, "[YSWIFT] Found %zu app classes\n", discoveredClasses->size());
  }
  
  // Load existing stats
  std::unordered_map<std::string, ClassLifecycleStats> existingStats;
  std::string filePath = getStatsPath();
  
  if (parseCSVStats(filePath, existingStats)) {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    *classStatsMap = existingStats;
    fprintf(stderr, "[YSWIFT] Loaded %zu previous stats\n", existingStats.size());
  }
}

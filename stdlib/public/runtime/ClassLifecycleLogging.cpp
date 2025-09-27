#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <mutex>
#include <objc/runtime.h>
#include <string>
#include <unordered_map>
#include <unordered_set>

// Forward declaration for nameForMetadata function
namespace swift {
  std::string nameForMetadata(const Metadata *type, bool qualified = false);
}

using namespace swift;

static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();

namespace {
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::unordered_set<std::string> *discoveredClasses = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
dispatch_queue_t trackingQueue = nullptr;
} // namespace

static void initializeTracking() {
  fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  discoveredClasses = new std::unordered_set<std::string>();
  classStatsMapMutex = new std::mutex();
  trackingQueue = dispatch_queue_create("com.swift.runtime.class_lifecycle_tracking", DISPATCH_QUEUE_SERIAL);

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
  if (!trackingInitialized.load()) {
    if (trackingInitialized.exchange(true)) return;
    initializeTracking();
  }

  if (metadata->getKind() != MetadataKind::Class) return;
  
  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty() || !discoveredClasses) return;

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  
  // Check if this qualified name is in our discovered classes
  if (discoveredClasses->find(qualifiedName) == discoveredClasses->end()) {
    return; // Class not found in discovered classes
  }

  auto &stats = (*classStatsMap)[qualifiedName];
  if (event[0] == 'I') { stats.initCount++; stats.isEverUsed = true; }
  else if (event[0] == 'D') { stats.deinitCount++; stats.isEverUsed = true; }
}

static void writeClassLifecycleStatisticsNow() {
  if (!trackingInitialized.load()) {
    return;
  }

  if (!classStatsMap || !classStatsMapMutex || !trackingQueue) {
    return;
  }

  dispatch_sync(trackingQueue, ^{
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);

    if (classStatsMap->empty()) {
      return;
    }

    const char *envPath = getenv("SWIFT_CLASS_STATS_OUTPUT");
    std::string outputPath = envPath && strlen(envPath) > 0 ? std::string(envPath) : "swift_class_lifecycle_stats.csv";
    std::ofstream outFile(outputPath);

    if (!outFile.is_open()) {
      return;
    }

    std::string csvContent;
    csvContent.reserve(classStatsMap->size() * 150);
    csvContent += "ClassName,InitCount,DeinitCount,IsUsed,HasLeak,LeakCount,Status\n";

    for (const auto &entry : *classStatsMap) {
      const std::string &className = entry.first;
      const ClassLifecycleStats &stats = entry.second;

      csvContent += "\"";
      csvContent += className;
      csvContent += "\",";
      csvContent += std::to_string(stats.initCount);
      csvContent += ",";
      csvContent += std::to_string(stats.deinitCount);
      csvContent += ",";
      csvContent += (stats.isEverUsed ? "TRUE" : "FALSE");
      csvContent += ",";

      bool hasLeak = (stats.initCount != stats.deinitCount) && stats.isEverUsed;
      long leakCount = hasLeak ? (static_cast<long>(stats.initCount) -
                                  static_cast<long>(stats.deinitCount))
                               : 0;

      csvContent += (hasLeak ? "TRUE" : "FALSE");
      csvContent += ",";
      csvContent += std::to_string(leakCount);
      csvContent += ",";

      if (!stats.isEverUsed) {
        csvContent += "UNUSED";
      } else if (hasLeak) {
        csvContent += "LEAK";
      } else {
        csvContent += "OK";
      }

      csvContent += "\n";
    }

    outFile << csvContent;
    outFile.close();
    fprintf(stderr,
            "[YSWIFT] *** CLASS LIFECYCLE STATISTICS WRITTEN TO: %s ***\n",
            outputPath.c_str());
  });
}

static bool isAppClass(Class cls) {
  if (!cls)
    return false;

  const char *imageName = class_getImageName(cls);
  if (!imageName)
    return false;

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
  const char *appName = getenv("SWIFT_APP_NAME");
  fprintf(stderr, "[YSWIFT] Scanning for %s.app classes\n", appName);

  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);

  if (classes) {
    for (unsigned int i = 0; i < numClasses; i++) {
      Class cls = classes[i];
      const char *className = class_getName(cls);

      if (className && isAppClass(cls)) {
        discoveredClassesSet.emplace(className);
      }
    }
    free(classes);
  }

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  classStatsMap->reserve(discoveredClassesSet.size());
  discoveredClasses->reserve(discoveredClassesSet.size());
  
  for (const auto &className : discoveredClassesSet) {
    (*classStatsMap)[className].isDiscovered = true;
    discoveredClasses->insert(className);
  }

  fprintf(stderr, "[YSWIFT] Found %zu app classes\n", discoveredClasses->size());
}

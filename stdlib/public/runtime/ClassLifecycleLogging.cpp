#include "ClassLifecycleLogging.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <string>
#include <unordered_map>
#include <set>

#include "swift/Runtime/Metadata.h"
#if SWIFT_OBJC_INTEROP
#include <objc/runtime.h>
#endif

using namespace swift;

// Forward declarations for functions used across namespaces
static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();

namespace {

std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
dispatch_queue_t trackingQueue = nullptr;

std::string getOutputFilePath() {
  const char *envPath = getenv("SWIFT_CLASS_STATS_OUTPUT");
  if (envPath && strlen(envPath) > 0) {
    return std::string(envPath);
  }
  return "swift_class_lifecycle_stats.csv";
}

} // namespace

void swift::logClassLifecycle(const HeapMetadata *metadata, const char *event) {
  if (!trackingInitialized.load()) {
    fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
    
    if (trackingInitialized.exchange(true))
      return;

    classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
    classStatsMapMutex = new std::mutex();

    trackingQueue = dispatch_queue_create(
        "com.swift.runtime.class_lifecycle_tracking", DISPATCH_QUEUE_SERIAL);

    fprintf(stderr, "[YSWIFT] Enumerating all classes in iOS Simulator target...\n");
    enumerateAllClassesInTarget();

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, 
                                                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 
                             5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
      fprintf(stderr, "[YSWIFT] *** Timer fired, writing stats ***\n");
      writeClassLifecycleStatisticsNow();
    });
    dispatch_resume(timer);
    
    atexit([]() {
      fprintf(stderr, "[YSWIFT] *** App terminating, final stats write ***\n");
      writeClassLifecycleStatisticsNow();
    });
  }

  if (metadata->getKind() != MetadataKind::Class)
    return;

  auto classMetadata = static_cast<const ClassMetadata *>(metadata);
  auto description = classMetadata->getDescription();
  if (!description)
    return;

  auto name = description->Name.get();
  if (!name)
    return;
  if (name[0] == '_' || strchr(name, '.') != nullptr)
    return;

  char *classNameCopy = strdup(name);
  char *eventCopy = strdup(event);

  dispatch_async(trackingQueue, ^{
    if (!classStatsMap || !classStatsMapMutex) {
      free(classNameCopy);
      free(eventCopy);
      return;
    }

    std::string className(classNameCopy);

    {
      std::lock_guard<std::mutex> lock(*classStatsMapMutex);
      auto &stats = (*classStatsMap)[className];

      if (strcmp(eventCopy, "INIT") == 0) {
        stats.initCount++;
        stats.isEverUsed = true;
      } else if (strcmp(eventCopy, "DEINIT") == 0) {
        stats.deinitCount++;
        stats.isEverUsed = true;
      }
    }

    // Clean up allocated memory
    free(classNameCopy);
    free(eventCopy);
  });
}

static void writeClassLifecycleStatisticsNow() {
  if (!trackingInitialized.load()) {
    return;
  }

  if (!classStatsMap || !classStatsMapMutex || !trackingQueue) {
    return;
  }

  // Wait for all background operations to complete before writing file
  dispatch_sync(trackingQueue, ^{
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);

    if (classStatsMap->empty()) {
      return;
    }

    std::string outputPath = getOutputFilePath();

    std::ofstream outFile(outputPath);

    if (!outFile.is_open()) {
      return;
    }

    // CSV Header
    outFile << "# Swift Class Lifecycle Statistics (iOS Simulator)\n";
    outFile << "# Target: iOS Simulator Application Classes Only\n";
    outFile << "#\n";
    outFile << "ClassName,InitCount,DeinitCount,IsUsed,HasLeak,LeakCount,Status\n";

    for (const auto &entry : *classStatsMap) {
      const std::string &className = entry.first;
      const ClassLifecycleStats &stats = entry.second;

      // CSV format: ClassName,InitCount,DeinitCount,IsUsed,HasLeak,LeakCount,Status
      outFile << "\"" << className << "\"," 
              << stats.initCount << ","
              << stats.deinitCount << ","
              << (stats.isEverUsed ? "TRUE" : "FALSE") << ",";

      // Memory leak detection
      bool hasLeak = (stats.initCount != stats.deinitCount) && stats.isEverUsed;
      long leakCount = hasLeak ? (static_cast<long>(stats.initCount) - static_cast<long>(stats.deinitCount)) : 0;
      
      outFile << (hasLeak ? "TRUE" : "FALSE") << ","
              << leakCount << ",";

      // Status column
      if (!stats.isEverUsed) {
        outFile << "UNUSED";
      } else if (hasLeak) {
        outFile << "LEAK";
      } else {
        outFile << "OK";
      }

      outFile << "\n";
    }

    // Calculate statistics
    size_t totalClasses = classStatsMap->size();
    size_t usedClasses = 0;
    size_t unusedClasses = 0;
    size_t classesWithLeaks = 0;
    
    for (const auto &entry : *classStatsMap) {
      const ClassLifecycleStats &stats = entry.second;
      if (stats.isEverUsed) {
        usedClasses++;
        if (stats.initCount != stats.deinitCount) {
          classesWithLeaks++;
        }
      } else {
        unusedClasses++;
      }
    }
    
    // Summary section as CSV comments and data
    outFile << "#\n";
    outFile << "# === SUMMARY (iOS Simulator) ===\n";
    outFile << "# Total application classes discovered: " << totalClasses << "\n";
    outFile << "# Used classes: " << usedClasses << "\n";
    outFile << "# Unused classes: " << unusedClasses << "\n";
    outFile << "# Classes with memory leaks: " << classesWithLeaks << "\n";
    
    if (totalClasses > 0) {
      double usageRate = (double)usedClasses / totalClasses * 100.0;
      outFile << "# Usage rate: " << std::fixed << std::setprecision(1) << usageRate << "%\n";
    }
    
    outFile << "#\n";
    outFile << "# Note: System classes (UIKit, Foundation, etc.) are filtered out.\n";
    outFile << "# Only your application's Swift classes are tracked.\n";
    outFile << "#\n";
    
    // Summary as additional CSV data for easy processing
    outFile << "\n# Summary Data (for easy parsing)\n";
    outFile << "Metric,Value\n";
    outFile << "\"Total Classes\"," << totalClasses << "\n";
    outFile << "\"Used Classes\"," << usedClasses << "\n";
    outFile << "\"Unused Classes\"," << unusedClasses << "\n";
    outFile << "\"Classes With Leaks\"," << classesWithLeaks << "\n";
    
    if (totalClasses > 0) {
      double usageRate = (double)usedClasses / totalClasses * 100.0;
      outFile << "\"Usage Rate %\"," << std::fixed << std::setprecision(1) << usageRate << "\n";
    }
    outFile.close();

    fprintf(stderr,
            "[YSWIFT] *** CLASS LIFECYCLE STATISTICS WRITTEN TO: %s ***\n",
            outputPath.c_str());
  });
}

static void enumerateAllClassesInTarget() {
  if (!classStatsMap || !classStatsMapMutex) {
    return;
  }

  std::set<std::string> discoveredClasses;

#if SWIFT_OBJC_INTEROP
  fprintf(stderr, "[YSWIFT] Using objc_copyClassList for iOS Simulator...\n");
  
  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);
  
  if (classes) {
    fprintf(stderr, "[YSWIFT] Found %u total classes in runtime\n", numClasses);
    
    for (unsigned int i = 0; i < numClasses; i++) {
      Class cls = classes[i];
      const char *className = class_getName(cls);
      
      if (className) {
         bool isSystemClass = (className[0] == '_' || strstr(className, "__") != nullptr);
        
        if (!isSystemClass) {
          std::string classNameStr(className);
          discoveredClasses.insert(classNameStr);
          fprintf(stderr, "[YSWIFT] Discovered class: %s\n", classNameStr.c_str());
        }
      }
    }
    
    free(classes);
  } else {
    fprintf(stderr, "[YSWIFT] Failed to get class list from Objective-C runtime\n");
  }
#else
  fprintf(stderr, "[YSWIFT] Warning: SWIFT_OBJC_INTEROP not available - limited class discovery\n");
#endif

  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);
    
    for (const auto &className : discoveredClasses) {
      auto &stats = (*classStatsMap)[className];
      stats.isDiscovered = true;
    }
    
    fprintf(stderr, "[YSWIFT] Total application classes discovered: %zu\n", discoveredClasses.size());
  }
}

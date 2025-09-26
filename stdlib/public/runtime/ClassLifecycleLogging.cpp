#include "ClassLifecycleLogging.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>

using namespace swift;

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
  return "swift_class_lifecycle_stats.txt";
}

void initializeTrackingOnFirstUse() {
  fprintf(stderr, "[YSWIFT] initializeTrackingOnFirstUse called\n");

  if (trackingInitialized.exchange(true))
    return;

  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();

  trackingQueue = dispatch_queue_create(
      "com.swift.runtime.class_lifecycle_tracking", DISPATCH_QUEUE_SERIAL);
}
} // namespace

void swift::logClassLifecycle(const HeapMetadata *metadata, const char *event) {
  if (!trackingInitialized.load()) {
    fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
    initializeTrackingOnFirstUse();
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
        fprintf(stderr, "[YSWIFT] *** INIT *** %s -> %lu\n", className.c_str(),
                stats.initCount);
      } else if (strcmp(eventCopy, "DEINIT") == 0) {
        stats.deinitCount++;
        fprintf(stderr, "[YSWIFT] *** DEINIT *** %s -> %lu\n",
                className.c_str(), stats.deinitCount);
      }
    }

    // Clean up allocated memory
    free(classNameCopy);
    free(eventCopy);
  });
}

void swift::writeClassLifecycleStatisticsNow() {
  fprintf(stderr,
          "[YSWIFT] *** Manual writeClassLifecycleStatisticsNow called ***\n");

  if (!trackingInitialized.load()) {
    fprintf(stderr, "[YSWIFT] Tracking not initialized, nothing to write\n");
    return;
  }

  if (!classStatsMap || !classStatsMapMutex || !trackingQueue) {
    fprintf(stderr, "[YSWIFT] Data structures not available\n");
    return;
  }

  fprintf(stderr, "[YSWIFT] Waiting for background queue to complete\n");

  // Wait for all background operations to complete before writing file
  dispatch_sync(trackingQueue, ^{
    fprintf(stderr, "[YSWIFT] Writing statistics to file\n");

    std::lock_guard<std::mutex> lock(*classStatsMapMutex);

    if (classStatsMap->empty()) {
      fprintf(stderr, "[YSWIFT] No data to write\n");
      return;
    }

    fprintf(stderr, "[YSWIFT] Found %zu classes to write\n",
            classStatsMap->size());

    std::string outputPath = getOutputFilePath();
    fprintf(stderr, "[YSWIFT] Output path: %s\n", outputPath.c_str());

    std::ofstream outFile(outputPath);

    if (!outFile.is_open()) {
      fprintf(stderr, "[YSWIFT] Failed to open file for class statistics: %s\n",
              outputPath.c_str());
      return;
    }

    outFile << "Swift Class Lifecycle Statistics\n";
    outFile << "=================================\n\n";
    outFile << "Format: ClassName -> Init Count / Deinit Count\n\n";

    for (const auto &entry : *classStatsMap) {
      const std::string &className = entry.first;
      const ClassLifecycleStats &stats = entry.second;

      fprintf(stderr, "[YSWIFT] Writing stats for %s: %lu/%lu\n",
              className.c_str(), stats.initCount, stats.deinitCount);

      outFile << className << " -> " << stats.initCount << " / "
              << stats.deinitCount;

      if (stats.initCount != stats.deinitCount) {
        long diff = static_cast<long>(stats.initCount) -
                    static_cast<long>(stats.deinitCount);
        outFile << " (LEAK WARNING: " << diff << " objects not deallocated)";
      }

      outFile << "\n";
    }

    outFile << "\nTotal classes tracked: " << classStatsMap->size() << "\n";
    outFile.close();

    fprintf(stderr,
            "[YSWIFT] *** CLASS LIFECYCLE STATISTICS WRITTEN TO: %s ***\n",
            outputPath.c_str());
  });
}

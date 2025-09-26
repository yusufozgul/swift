#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
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
// Global tracking data structures (initialized on first use)
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
dispatch_queue_t trackingQueue = nullptr;

// Get the output file path from environment or use default
std::string getOutputFilePath() {
  const char *envPath = getenv("SWIFT_CLASS_STATS_OUTPUT");
  if (envPath && strlen(envPath) > 0) {
    return std::string(envPath);
  }
  return "swift_class_lifecycle_stats.txt";
}

// Lazy initialization function called on first logClassLifecycle call
void initializeTrackingOnFirstUse() {
  if (trackingInitialized.exchange(true)) {
    return; // Already initialized
  }

  // Initialize tracking data structures
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  classStatsMapMutex = new std::mutex();

  // Create a background queue for tracking operations
  trackingQueue = dispatch_queue_create(
      "com.swift.runtime.class_lifecycle_tracking", DISPATCH_QUEUE_SERIAL);

  // Register cleanup function to be called at program termination
  atexit([]() {
    if (!classStatsMap || !classStatsMapMutex || !trackingQueue) {
      return;
    }

    // Wait for all background operations to complete before writing file
    dispatch_sync(trackingQueue, ^{
      std::lock_guard<std::mutex> lock(*classStatsMapMutex);

      if (classStatsMap->empty()) {
        return; // No data to write
      }

      std::string outputPath = getOutputFilePath();
      std::ofstream outFile(outputPath);

      if (!outFile.is_open()) {
        fprintf(stderr, "Failed to open file for class statistics: %s\n",
                outputPath.c_str());
        return;
      }

      outFile << "Swift Class Lifecycle Statistics\n";
      outFile << "=================================\n\n";
      outFile << "Format: ClassName -> Init Count / Deinit Count\n\n";

      for (const auto &entry : *classStatsMap) {
        const std::string &className = entry.first;
        const ClassLifecycleStats &stats = entry.second;

        outFile << className << " -> " << stats.initCount << " / "
                << stats.deinitCount;

        // Add warning if counts don't match (potential memory leaks)
        if (stats.initCount != stats.deinitCount) {
          long diff = static_cast<long>(stats.initCount) -
                      static_cast<long>(stats.deinitCount);
          outFile << " (LEAK WARNING: " << diff << " objects not deallocated)";
        }

        outFile << "\n";
      }

      outFile << "\nTotal classes tracked: " << classStatsMap->size() << "\n";
      outFile.close();

      fprintf(stderr, "Class lifecycle statistics written to: %s\n",
              outputPath.c_str());
    });
  });
}
} // namespace

void swift::logClassLifecycle(const HeapMetadata *metadata, const char *event) {
  // Initialize tracking on first call
  if (!trackingInitialized.load()) {
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

  // Copy the class name and event to avoid pointer issues in async block
  char *classNameCopy = strdup(name);
  char *eventCopy = strdup(event);

  // Dispatch the tracking work to background queue
  dispatch_async(trackingQueue, ^{
    if (!classStatsMap || !classStatsMapMutex) {
      free(classNameCopy);
      free(eventCopy);
      return;
    }

    std::string className(classNameCopy);

    // Update statistics in background
    {
      std::lock_guard<std::mutex> lock(*classStatsMapMutex);
      auto &stats = (*classStatsMap)[className];

      if (strcmp(eventCopy, "INIT") == 0) {
        stats.initCount++;
      } else if (strcmp(eventCopy, "DEINIT") == 0) {
        stats.deinitCount++;
      }
    }

    // Clean up allocated memory
    free(classNameCopy);
    free(eventCopy);
  });
}

#include "ClassTracker.h"
#include "ClassDiscover.h"
#include "AssetTracker.h"
#include "AssetDiscover.h"
#include "SharedMemory.h"
#include "swift/Runtime/Metadata.h"
#include "swift/Runtime/HeapObject.h"
#include <atomic>
#include <mutex>
#include <unordered_map>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace swift;

// =============================================================================
// MUTEX ARCHITECTURE & LOCK ORDERING
// =============================================================================
//
// This module uses ONE std::mutex for local stats (in-process synchronization).
// It coordinates with SharedMemory's pthread_mutex (inter-process sync).
//
// CRITICAL RULES TO PREVENT DEADLOCK:
// 1. Lock Level 1 (local classStatsMapMutex) FIRST
// 2. Release Level 1 BEFORE calling SharedMemory functions
// 3. SharedMemory functions acquire Level 2 (pthread_mutex) internally
// 4. NEVER hold both locks simultaneously
//
// Lock Ordering:
//   Level 1: classStatsMapMutex (local, std::mutex)
//   Level 2: sharedMemory->mutex (shared, pthread_mutex)
//
// =============================================================================

namespace {
std::unordered_map<std::string, ClassStats> *classStatsMap = nullptr;
std::unordered_map<std::string, uint32_t> *classIndexMap = nullptr; // Maps class name to shared memory index
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
} // namespace

static void initializeTracking() {
  classStatsMap = new std::unordered_map<std::string, ClassStats>();
  classIndexMap = new std::unordered_map<std::string, uint32_t>();
  classStatsMapMutex = new std::mutex();
  initializeSharedMemory();

  // Run discovery if enabled (will exit after discovery)
  const char *classDiscoverMode = getenv("RUNTIME_DISCOVER");
  const char *assetDiscoverMode = getenv("RUNTIME_ASSET_DISCOVER");
  bool shouldDiscoverClasses = classDiscoverMode && strcmp(classDiscoverMode, "true") == 0;
  bool shouldDiscoverAssets = assetDiscoverMode && strcmp(assetDiscoverMode, "true") == 0;

  if (shouldDiscoverClasses) {
    discoverAllClasses();
  }
  if (shouldDiscoverAssets) {
    discoverAllAssets();
  }

  if (shouldDiscoverClasses || shouldDiscoverAssets) {
    fprintf(stderr, "[YSWIFT] All discovery completed, exiting application\n");
    exit(0);
  }

  // Initialize asset tracking for normal runs
  forceAssetTrackingInitialization();

  // Load discovered classes and initialize tracking
  auto appClassNames = loadDiscoveredClasses();

  // Only populate classStatsMap if appClassNames is not empty
  if (appClassNames.empty()) {
    fprintf(stderr, "[YSWIFT] No classes to track, skipping initialization\n");
    return;
  }

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  classStatsMap->reserve(appClassNames.size());
  classIndexMap->reserve(appClassNames.size());

  // Load existing stats from shared memory first
  std::unordered_map<std::string, ClassStats> existingStats;
  parseSharedMemoryStats(existingStats);

  // Initialize local map with existing stats or zeros
  for (const auto& name : appClassNames) {
    auto it = existingStats.find(name);
    (*classStatsMap)[name] = (it != existingStats.end()) ? it->second : ClassStats{0, 0};
  }

  // Sync all classes to shared memory and build index map
  syncClassesToSharedMemory(*classStatsMap, *classIndexMap);

  fprintf(stderr, "[YSWIFT] Tracking initialized\n");
}

static void ensureTrackingInitialized() {
  static std::once_flag initFlag;
  std::call_once(initFlag, []() {
    initializeTracking();
    trackingInitialized.store(true, std::memory_order_release);
  });
}

void swift::logClassLifecycle(const HeapObject *object, const char *event) {
  if (!object || !event) return;
  if (!trackingInitialized.load(std::memory_order_acquire)) {
    ensureTrackingInitialized();
  }

  const HeapMetadata *metadata = object->metadata;
  if (!metadata || metadata->getKind() != MetadataKind::Class) return;
  if (!classStatsMap || !classIndexMap || !getSharedMemory()) return;

  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty()) return;

  // Determine if this is init or deinit
  const bool isInit = (event[0] == 'I');
  const bool isDeinit = (event[0] == 'D');
  if (!isInit && !isDeinit) return;

  // CRITICAL: Separate local and shared memory updates to avoid nested locking
  // Step 1: Update local stats (acquire Level 1 lock)
  ClassStats updatedStats;
  uint32_t classIndex;
  bool shouldUpdate = false;

  {
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);

    // Check if we're tracking this class
    auto statsIt = classStatsMap->find(qualifiedName);
    if (statsIt == classStatsMap->end()) return;

    auto indexIt = classIndexMap->find(qualifiedName);
    if (indexIt == classIndexMap->end()) return;

    // Update local stats
    if (isInit) {
      statsIt->second.initCount++;
    } else {
      statsIt->second.deinitCount++;
    }

    // Copy values for shared memory update
    updatedStats = statsIt->second;
    classIndex = indexIt->second;
    shouldUpdate = true;

    // Level 1 lock released here
  }

  // Step 2: Update shared memory (will acquire Level 2 lock internally)
  // NO LOCK HELD HERE - safe to call SharedMemory functions
  if (shouldUpdate) {
    updateSharedMemoryStats(qualifiedName, classIndex, updatedStats);
  }
}

bool swift::isTrackingInitialized() {
  return trackingInitialized.load(std::memory_order_acquire);
}

void swift::forceTrackingInitialization() {
  ensureTrackingInitialized();
}

std::unordered_map<std::string, ClassStats> swift::getClassStats() {
  if (!classStatsMap || !classStatsMapMutex) {
    return std::unordered_map<std::string, ClassStats>();
  }

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  return *classStatsMap;
}
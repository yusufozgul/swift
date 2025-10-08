#include "AssetTracker.h"
#include "AssetDiscover.h"
#include "SharedMemory.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <atomic>
#include <mutex>
#include <unordered_map>
#include <cstdio>
#include <cstring>

using namespace swift;

// =============================================================================
// MUTEX ARCHITECTURE & LOCK ORDERING
// =============================================================================
//
// This module uses ONE std::mutex for local asset stats (in-process sync).
// It coordinates with SharedMemory's pthread_mutex (inter-process sync).
//
// CRITICAL RULES TO PREVENT DEADLOCK:
// 1. Lock Level 1 (local assetStatsMapMutex) FIRST
// 2. Release Level 1 BEFORE calling SharedMemory functions
// 3. SharedMemory functions acquire Level 2 (pthread_mutex) internally
// 4. NEVER hold both locks simultaneously
//
// Lock Ordering:
//   Level 1: assetStatsMapMutex (local, std::mutex)
//   Level 2: sharedMemory->mutex (shared, pthread_mutex)
//
// =============================================================================

namespace {
std::unordered_map<std::string, AssetStats> *assetStatsMap = nullptr;
std::unordered_map<std::string, uint32_t> *assetIndexMap = nullptr;
std::mutex *assetStatsMapMutex = nullptr;
std::atomic<bool> assetTrackingInitialized{false};
} // namespace

static void initializeAssetTracking() {
  assetStatsMap = new std::unordered_map<std::string, AssetStats>();
  assetIndexMap = new std::unordered_map<std::string, uint32_t>();
  assetStatsMapMutex = new std::mutex();
  initializeSharedMemory();

  // Load discovered assets and initialize tracking
  auto discoveredAssets = loadDiscoveredAssets();

  // Only populate assetStatsMap if discoveredAssets is not empty
  if (discoveredAssets.empty()) {
    fprintf(stderr, "[YSWIFT] No assets to track, skipping asset tracking initialization\n");
    return;
  }

  std::lock_guard<std::mutex> lock(*assetStatsMapMutex);
  assetStatsMap->reserve(discoveredAssets.size());
  assetIndexMap->reserve(discoveredAssets.size());

  // Load existing stats from shared memory first
  std::unordered_map<std::string, AssetStats> existingStats;
  parseSharedMemoryAssetStats(existingStats);

  // Initialize local map with existing stats or zeros
  for (const auto& name : discoveredAssets) {
    auto it = existingStats.find(name);
    (*assetStatsMap)[name] = (it != existingStats.end()) ? it->second : AssetStats{0};
  }

  // Sync all assets to shared memory and build index map
  syncAssetsToSharedMemory(*assetStatsMap, *assetIndexMap);

  fprintf(stderr, "[YSWIFT] Asset tracking initialized with %zu assets\n", discoveredAssets.size());
}

static void ensureAssetTrackingInitialized() {
  static std::once_flag initFlag;
  std::call_once(initFlag, []() {
    assetTrackingInitialized.store(true, std::memory_order_release);
    initializeAssetTracking();
  });
}

bool swift::isAssetTrackingInitialized() {
  return assetTrackingInitialized.load(std::memory_order_acquire);
}

void swift::forceAssetTrackingInitialization() {
  ensureAssetTrackingInitialized();
}

std::unordered_map<std::string, AssetStats> swift::getAssetStats() {
  if (!assetStatsMap || !assetStatsMapMutex) {
    return std::unordered_map<std::string, AssetStats>();
  }

  std::lock_guard<std::mutex> lock(*assetStatsMapMutex);
  return *assetStatsMap;
}

void swift::logAssetAccess(const char* bundleID, const char* resourceName) {
  if (!bundleID || !resourceName) return;

  if (!assetTrackingInitialized.load(std::memory_order_acquire)) {
    ensureAssetTrackingInitialized();
  }

  if (!assetStatsMap || !assetIndexMap || !getSharedMemory()) return;

  // Create full asset name: BundleID:AssetName
  char fullAssetName[MAX_ASSET_NAME_LENGTH];
  snprintf(fullAssetName, sizeof(fullAssetName), "%s:%s", bundleID, resourceName);

  // CRITICAL: Separate local and shared memory updates to avoid nested locking
  // Step 1: Update local stats (acquire Level 1 lock)
  AssetStats updatedStats;
  uint32_t assetIndex;
  bool shouldUpdate = false;

  {
    std::lock_guard<std::mutex> lock(*assetStatsMapMutex);

    // Check if we're tracking this asset
    auto statsIt = assetStatsMap->find(fullAssetName);
    if (statsIt == assetStatsMap->end()) return;

    auto indexIt = assetIndexMap->find(fullAssetName);
    if (indexIt == assetIndexMap->end()) return;

    // Update local stats
    statsIt->second.accessCount++;

    // Copy values for shared memory update
    updatedStats = statsIt->second;
    assetIndex = indexIt->second;
    shouldUpdate = true;

    // Level 1 lock released here
  }

  // Step 2: Update shared memory (will acquire Level 2 lock internally)
  // NO LOCK HELD HERE - safe to call SharedMemory functions
  if (shouldUpdate) {
    updateSharedMemoryAssetStats(fullAssetName, assetIndex, updatedStats);
  }
}

// ============================================================================
// CFBundle API Hooking using DYLD_INTERPOSE
// ============================================================================

// Function pointer types for original CFBundle functions
typedef CFURLRef (*CFBundleCopyResourceURLFunc)(CFBundleRef bundle, CFStringRef resourceName,
                                                 CFStringRef resourceType, CFStringRef subDirName);

typedef void* (*CFBundleGetDataPointerForNameFunc)(CFBundleRef bundle, CFStringRef symbolName);

// Store original function pointers
static CFBundleCopyResourceURLFunc original_CFBundleCopyResourceURL = nullptr;
static CFBundleGetDataPointerForNameFunc original_CFBundleGetDataPointerForName = nullptr;

// Helper: Get bundle identifier from CFBundleRef
// NOTE: Returns pointer to STACK buffer, caller must use immediately
static const char* getBundleIDFromBundle(CFBundleRef bundle, char* outBuffer, size_t bufferSize) {
  if (!bundle || !outBuffer || bufferSize == 0) return nullptr;

  CFStringRef identifier = CFBundleGetIdentifier(bundle);

  if (identifier && CFStringGetCString(identifier, outBuffer, bufferSize, kCFStringEncodingUTF8)) {
    return outBuffer;
  }

  return nullptr;
}

// Helper: Get resource name from CFStringRef
// NOTE: Returns pointer to STACK buffer, caller must use immediately
static const char* getResourceNameFromCFString(CFStringRef resourceName, char* outBuffer, size_t bufferSize) {
  if (!resourceName || !outBuffer || bufferSize == 0) return nullptr;

  if (CFStringGetCString(resourceName, outBuffer, bufferSize, kCFStringEncodingUTF8)) {
    return outBuffer;
  }

  return nullptr;
}

// Hooked version of CFBundleCopyResourceURL
static CFURLRef hooked_CFBundleCopyResourceURL(CFBundleRef bundle, CFStringRef resourceName,
                                                CFStringRef resourceType, CFStringRef subDirName) {
  // Get original function pointer if not set
  if (!original_CFBundleCopyResourceURL) {
    original_CFBundleCopyResourceURL = (CFBundleCopyResourceURLFunc)dlsym(RTLD_NEXT, "CFBundleCopyResourceURL");
  }

  // Log the asset access using STACK buffers (thread-safe, no memory leaks)
  char bundleIDBuffer[256];
  char resourceNameBuffer[256];

  const char* bundleID = getBundleIDFromBundle(bundle, bundleIDBuffer, sizeof(bundleIDBuffer));
  const char* resName = getResourceNameFromCFString(resourceName, resourceNameBuffer, sizeof(resourceNameBuffer));

  if (bundleID && resName) {
    logAssetAccess(bundleID, resName);
  }

  // Call original function
  if (original_CFBundleCopyResourceURL) {
    return original_CFBundleCopyResourceURL(bundle, resourceName, resourceType, subDirName);
  }

  return nullptr;
}

// Hooked version of CFBundleGetDataPointerForName
static void* hooked_CFBundleGetDataPointerForName(CFBundleRef bundle, CFStringRef symbolName) {
  // Get original function pointer if not set
  if (!original_CFBundleGetDataPointerForName) {
    original_CFBundleGetDataPointerForName = (CFBundleGetDataPointerForNameFunc)dlsym(RTLD_NEXT, "CFBundleGetDataPointerForName");
  }

  // Log the asset access using STACK buffers (thread-safe, no memory leaks)
  char bundleIDBuffer[256];
  char symbolNameBuffer[256];

  const char* bundleID = getBundleIDFromBundle(bundle, bundleIDBuffer, sizeof(bundleIDBuffer));
  const char* symName = getResourceNameFromCFString(symbolName, symbolNameBuffer, sizeof(symbolNameBuffer));

  if (bundleID && symName) {
    logAssetAccess(bundleID, symName);
  }

  // Call original function
  if (original_CFBundleGetDataPointerForName) {
    return original_CFBundleGetDataPointerForName(bundle, symbolName);
  }

  return nullptr;
}

// DYLD interpose definitions
#define DYLD_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { \
    const void* replacement; \
    const void* replacee; \
  } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
    (const void*)(unsigned long)&_replacement, \
    (const void*)(unsigned long)&_replacee \
  };

DYLD_INTERPOSE(hooked_CFBundleCopyResourceURL, CFBundleCopyResourceURL)
DYLD_INTERPOSE(hooked_CFBundleGetDataPointerForName, CFBundleGetDataPointerForName)

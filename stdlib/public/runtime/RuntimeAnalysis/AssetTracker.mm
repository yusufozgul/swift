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

  std::lock_guard<std::mutex> lock(*assetStatsMapMutex);

  // Check if we're tracking this asset
  auto statsIt = assetStatsMap->find(fullAssetName);
  if (statsIt == assetStatsMap->end()) return;

  auto indexIt = assetIndexMap->find(fullAssetName);
  if (indexIt == assetIndexMap->end()) return;

  // Update local stats
  statsIt->second.accessCount++;

  // Update shared memory
  uint32_t index = indexIt->second;
  updateSharedMemoryAssetStats(fullAssetName, index, statsIt->second);
}

// ============================================================================
// CFBundle API Hooking using DYLD_INTERPOSE
// ============================================================================

// Function pointer types for original CFBundle functions
typedef CFURLRef (*CFBundleGetResourceURLFunc)(CFBundleRef bundle, CFStringRef resourceName,
                                                CFStringRef resourceType, CFStringRef subDirName);

typedef void* (*CFBundleGetDataPointerForNameFunc)(CFBundleRef bundle, CFStringRef symbolName);

// Store original function pointers
static CFBundleGetResourceURLFunc original_CFBundleGetResourceURL = nullptr;
static CFBundleGetDataPointerForNameFunc original_CFBundleGetDataPointerForName = nullptr;

// Helper: Get bundle identifier from CFBundleRef
static const char* getBundleIDFromBundle(CFBundleRef bundle) {
  if (!bundle) return nullptr;

  static __thread char bundleIDBuffer[256];
  CFStringRef identifier = CFBundleGetIdentifier(bundle);

  if (identifier && CFStringGetCString(identifier, bundleIDBuffer, sizeof(bundleIDBuffer), kCFStringEncodingUTF8)) {
    return bundleIDBuffer;
  }

  return nullptr;
}

// Helper: Get resource name from CFStringRef
static const char* getResourceNameFromCFString(CFStringRef resourceName) {
  if (!resourceName) return nullptr;

  static __thread char resourceBuffer[256];
  if (CFStringGetCString(resourceName, resourceBuffer, sizeof(resourceBuffer), kCFStringEncodingUTF8)) {
    return resourceBuffer;
  }

  return nullptr;
}

// Hooked version of CFBundleGetResourceURL
static CFURLRef hooked_CFBundleGetResourceURL(CFBundleRef bundle, CFStringRef resourceName,
                                               CFStringRef resourceType, CFStringRef subDirName) {
  // Get original function pointer if not set
  if (!original_CFBundleGetResourceURL) {
    original_CFBundleGetResourceURL = (CFBundleGetResourceURLFunc)dlsym(RTLD_NEXT, "CFBundleGetResourceURL");
  }

  // Log the asset access
  const char* bundleID = getBundleIDFromBundle(bundle);
  const char* resName = getResourceNameFromCFString(resourceName);

  if (bundleID && resName) {
    logAssetAccess(bundleID, resName);
  }

  // Call original function
  if (original_CFBundleGetResourceURL) {
    return original_CFBundleGetResourceURL(bundle, resourceName, resourceType, subDirName);
  }

  return nullptr;
}

// Hooked version of CFBundleGetDataPointerForName
static void* hooked_CFBundleGetDataPointerForName(CFBundleRef bundle, CFStringRef symbolName) {
  // Get original function pointer if not set
  if (!original_CFBundleGetDataPointerForName) {
    original_CFBundleGetDataPointerForName = (CFBundleGetDataPointerForNameFunc)dlsym(RTLD_NEXT, "CFBundleGetDataPointerForName");
  }

  // Log the asset access (for data assets)
  const char* bundleID = getBundleIDFromBundle(bundle);
  const char* symName = getResourceNameFromCFString(symbolName);

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

DYLD_INTERPOSE(hooked_CFBundleGetResourceURL, CFBundleGetResourceURL)
DYLD_INTERPOSE(hooked_CFBundleGetDataPointerForName, CFBundleGetDataPointerForName)

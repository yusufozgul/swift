#ifndef SWIFT_RUNTIME_ASSETTRACKER_H
#define SWIFT_RUNTIME_ASSETTRACKER_H

#include "SharedMemory.h"
#include <unordered_map>

// =============================================================================
// ASSET TRACKING - THREAD SAFETY
// =============================================================================
//
// This module tracks asset access events via CFBundle API hooking.
// All public functions are THREAD-SAFE.
//
// MUTEX ARCHITECTURE:
// - Uses internal std::mutex (assetStatsMapMutex) for local stats
// - Coordinates with SharedMemory's pthread_mutex for inter-process sync
// - STRICT lock ordering prevents deadlock
//
// LOCK ORDERING:
//   Level 1: assetStatsMapMutex (acquired FIRST, released FIRST)
//   Level 2: sharedMemory->mutex (acquired AFTER Level 1 is released)
//
// IMPLEMENTATION DETAILS:
// - logAssetAccess updates local stats under Level 1 lock
// - Then releases Level 1 lock completely
// - Then calls SharedMemory functions (which acquire Level 2 lock)
// - This ensures NO nested locking ever occurs
//
// MEMORY SAFETY:
// - Uses STACK buffers (not thread-local) to avoid memory leaks
// - Safe for use with thread pools
//
// =============================================================================

namespace swift {

/// Check if asset tracking has been initialized
/// \returns true if tracking is ready, false otherwise
bool isAssetTrackingInitialized();

/// Force initialization of asset tracking system
/// This is called automatically but can be called manually
void forceAssetTrackingInitialization();

/// Get a copy of current asset statistics
/// \returns Map of asset names (BundleID:AssetName) to their statistics
std::unordered_map<std::string, AssetStats> getAssetStats();

/// Log asset access for tracking purposes
/// This function is called from CFBundle hooks
/// \param bundleID Bundle identifier
/// \param resourceName Resource name being accessed
void logAssetAccess(const char* bundleID, const char* resourceName);

} // namespace swift

#endif // SWIFT_RUNTIME_ASSETTRACKER_H

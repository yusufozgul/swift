#ifndef SWIFT_RUNTIME_ASSETTRACKER_H
#define SWIFT_RUNTIME_ASSETTRACKER_H

#include "SharedMemory.h"
#include <unordered_map>

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

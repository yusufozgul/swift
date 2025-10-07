#ifndef SWIFT_RUNTIME_ASSETDISCOVER_H
#define SWIFT_RUNTIME_ASSETDISCOVER_H

#include <string>
#include <vector>

namespace swift {

/// Discover all assets from application bundles and optionally save them to a file
/// This is used in discovery mode to identify which assets should be tracked
/// Assets are discovered from all loaded bundles and stored in format: BundleID:AssetName
void discoverAllAssets();

/// Load previously discovered assets from a file
/// \returns Vector of asset names to track (in BundleID:AssetName format)
std::vector<std::string> loadDiscoveredAssets();

} // namespace swift

#endif // SWIFT_RUNTIME_ASSETDISCOVER_H

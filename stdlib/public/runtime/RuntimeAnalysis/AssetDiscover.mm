#include "AssetDiscover.h"
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <fstream>
#include <vector>
#include <set>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dirent.h>
#include <sys/stat.h>

using namespace swift;

// Get bundle identifier from bundle path
static std::string getBundleIdentifier(CFBundleRef bundle) {
  if (!bundle) return "";

  CFStringRef identifier = CFBundleGetIdentifier(bundle);
  if (!identifier) {
    // Fallback: use bundle name
    CFURLRef bundleURL = CFBundleCopyBundleURL(bundle);
    if (bundleURL) {
      CFStringRef bundleName = CFURLCopyLastPathComponent(bundleURL);
      if (bundleName) {
        char buffer[256];
        if (CFStringGetCString(bundleName, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
          // Remove .app, .framework, .bundle extension
          char *dot = strrchr(buffer, '.');
          if (dot) *dot = '\0';
          CFRelease(bundleName);
          CFRelease(bundleURL);
          return std::string(buffer);
        }
        CFRelease(bundleName);
      }
      CFRelease(bundleURL);
    }
    return "unknown";
  }

  char buffer[256];
  if (CFStringGetCString(identifier, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
    return std::string(buffer);
  }
  return "unknown";
}

// Check if this is an app bundle (not system framework)
static bool isAppBundle(const char *imagePath) {
  if (!imagePath) return false;

  static char bundlePath[512] = {0};
  static size_t bundlePathLen = 0;
  if (!bundlePath[0]) {
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
      const struct mach_header *hdr = _dyld_get_image_header(i);
      if (hdr && hdr->filetype == MH_EXECUTE) {
        const char *path = _dyld_get_image_name(i);
        const char *app = path ? strstr(path, ".app/") : nullptr;
        if (app && (size_t)(app - path + 5) < sizeof(bundlePath)) {
          bundlePathLen = (size_t)(app - path + 5);
          snprintf(bundlePath, sizeof(bundlePath), "%.*s", (int)bundlePathLen, path);
          fprintf(stderr, "[YSWIFT] Main app bundle path: %s\n", bundlePath);
        }
        break;
      }
    }
  }

  if (!bundlePath[0]) return false;
  return strncmp(imagePath, bundlePath, bundlePathLen) == 0;
}

// Scan directory for image resources (png, jpg, pdf, etc.)
static void scanDirectoryForAssets(const char *dirPath, const std::string &bundleID, std::set<std::string> &assets) {
  DIR *dir = opendir(dirPath);
  if (!dir) return;

  struct dirent *entry;
  while ((entry = readdir(dir)) != nullptr) {
    if (entry->d_name[0] == '.') continue;

    char fullPath[1024];
    snprintf(fullPath, sizeof(fullPath), "%s/%s", dirPath, entry->d_name);

    struct stat statbuf;
    if (stat(fullPath, &statbuf) != 0) continue;

    if (S_ISDIR(statbuf.st_mode)) {
      // Recursively scan subdirectories
      scanDirectoryForAssets(fullPath, bundleID, assets);
    } else {
      // Check for image file extensions
      const char *ext = strrchr(entry->d_name, '.');
      if (ext && (strcasecmp(ext, ".png") == 0 ||
                  strcasecmp(ext, ".jpg") == 0 ||
                  strcasecmp(ext, ".jpeg") == 0 ||
                  strcasecmp(ext, ".pdf") == 0 ||
                  strcasecmp(ext, ".gif") == 0 ||
                  strcasecmp(ext, ".heic") == 0)) {
        // Remove extension to get asset name
        char assetName[256];
        size_t nameLen = ext - entry->d_name;
        if (nameLen < sizeof(assetName)) {
          strncpy(assetName, entry->d_name, nameLen);
          assetName[nameLen] = '\0';

          // Format: BundleID:AssetName
          std::string fullAssetName = bundleID + ":" + assetName;
          assets.insert(fullAssetName);
        }
      }
    }
  }

  closedir(dir);
}

// Discover assets from a specific bundle
static void discoverAssetsInBundle(CFBundleRef bundle, std::set<std::string> &assets) {
  if (!bundle) return;

  std::string bundleID = getBundleIdentifier(bundle);

  // Get bundle's resource URL
  CFURLRef resourceURL = CFBundleCopyResourcesDirectoryURL(bundle);
  if (!resourceURL) return;

  char resourcePath[1024];
  if (CFURLGetFileSystemRepresentation(resourceURL, true, (UInt8*)resourcePath, sizeof(resourcePath))) {
    fprintf(stderr, "[YSWIFT] Scanning bundle resources: %s (%s)\n", bundleID.c_str(), resourcePath);
    scanDirectoryForAssets(resourcePath, bundleID, assets);
  }

  CFRelease(resourceURL);

  // Also check for Assets.car (compiled asset catalog)
  CFURLRef assetsCar = CFBundleCopyResourceURL(bundle, CFSTR("Assets"), CFSTR("car"), nullptr);
  if (assetsCar) {
    fprintf(stderr, "[YSWIFT] Found Assets.car in bundle: %s\n", bundleID.c_str());
    // Note: Parsing .car files requires private APIs or reverse engineering
    // For now, we'll just note its presence
    // In a production system, you could use tools like 'acextract' or parse the binary format
    CFRelease(assetsCar);
  }
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
void swift::discoverAllAssets() {
#else
void swift::discoverAllAssets() __attribute__((unused));
void swift::discoverAllAssets() {
#endif
  const char *discoverMode = getenv("RUNTIME_ASSET_DISCOVER");
  const char *assetListPath = getenv("RUNTIME_ASSET_DISCOVER_RESULT");
  bool shouldDiscover = discoverMode && strcmp(discoverMode, "true") == 0;

  if (!assetListPath || !shouldDiscover) return;

  std::set<std::string> allAssets;

  // Get all loaded bundles from dyld images
  for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
    const char *imagePath = _dyld_get_image_name(i);
    if (!imagePath) continue;

    // Only process app bundles, not system frameworks
    if (!isAppBundle(imagePath)) continue;

    // Try to get bundle for this image
    CFStringRef pathStr = CFStringCreateWithCString(nullptr, imagePath, kCFStringEncodingUTF8);
    if (!pathStr) continue;

    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, pathStr, kCFURLPOSIXPathStyle, false);
    CFRelease(pathStr);

    if (!url) continue;

    CFBundleRef bundle = CFBundleCreate(nullptr, url);
    CFRelease(url);

    if (bundle) {
      discoverAssetsInBundle(bundle, allAssets);
      CFRelease(bundle);
    }
  }

  // Also check main bundle
  CFBundleRef mainBundle = CFBundleGetMainBundle();
  if (mainBundle) {
    discoverAssetsInBundle(mainBundle, allAssets);
  }

  // Write to file
  std::ofstream file(assetListPath);
  for (const auto& asset : allAssets) {
    file << asset << '\n';
  }

  fprintf(stderr, "[YSWIFT] Discovered %zu assets written to: %s\n", allAssets.size(), assetListPath);
  fprintf(stderr, "[YSWIFT] Asset discovery completed, exiting application\n");
  exit(0);
}

std::vector<std::string> swift::loadDiscoveredAssets() {
  std::vector<std::string> assets;
  const char *assetListPath = getenv("RUNTIME_ASSET_DISCOVER_RESULT");

  if (assetListPath) {
    std::ifstream file(assetListPath);
    std::string line;
    while (std::getline(file, line)) {
      if (!line.empty()) assets.push_back(line);
    }
    fprintf(stderr, "[YSWIFT] Loaded %zu assets from: %s\n", assets.size(), assetListPath);
  }

  return assets;
}

/*
 * Environment Variables:
 *
 * RUNTIME_ASSET_DISCOVER
 *   - Set to "true" to enable asset discovery mode (scans all bundles, writes to file, then exits)
 *
 * RUNTIME_ASSET_DISCOVER_RESULT
 *   - File path for reading/writing the list of assets to track
 *   - Format: BundleID:AssetName (e.g., "com.myapp:icon_home")
 */

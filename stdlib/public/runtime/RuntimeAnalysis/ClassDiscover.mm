#include "ClassDiscover.h"
#include <objc/runtime.h>
#include <fstream>
#include <vector>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

using namespace swift;

static bool isAppClass(Class cls) {
  if (!cls) return false;
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;

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
          fprintf(stderr, "[YSWIFT] Main bundle path: %s\n", bundlePath);
        }
        break;
      }
    }
  }

  if (!bundlePath[0] || strncmp(imageName, bundlePath, bundlePathLen) != 0) return false;
  // Exclude classes from Frameworks folder
  return strstr(imageName, "/Frameworks/") == nullptr;
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
void swift::discoverAllClasses() {
#else
void swift::discoverAllClasses() __attribute__((unused));
void swift::discoverAllClasses() {
#endif
  const char *discoverMode = getenv("RUNTIME_DISCOVER");
  const char *classListPath = getenv("RUNTIME_DISCOVER_RESULT");
  bool shouldDiscover = discoverMode && strcmp(discoverMode, "true") == 0;

  std::vector<std::string> appClassNames;

  if (classListPath && shouldDiscover) {
    unsigned int numClasses = 0;
    Class *classes = objc_copyClassList(&numClasses);

    if (classes) {
      for (unsigned int i = 0; i < numClasses; i++) {
        if (isAppClass(classes[i])) {
          const char *name = class_getName(classes[i]);
          if (name) appClassNames.push_back(name);
        }
      }
      free(classes);

      std::ofstream file(classListPath);
      for (const auto& name : appClassNames) file << name << '\n';
      fprintf(stderr, "[YSWIFT] Discovered %zu classes written to: %s\n", appClassNames.size(), classListPath);
      fprintf(stderr, "[YSWIFT] Discovery completed, exiting application\n");
      exit(0);
    }
  }
}

std::vector<std::string> swift::loadDiscoveredClasses() {
  std::vector<std::string> appClassNames;
  const char *classListPath = getenv("RUNTIME_DISCOVER_RESULT");

  if (classListPath) {
    std::ifstream file(classListPath);
    std::string line;
    while (std::getline(file, line)) {
      if (!line.empty()) appClassNames.push_back(line);
    }
    fprintf(stderr, "[YSWIFT] Loaded %zu classes from: %s\n", appClassNames.size(), classListPath);
  }

  return appClassNames;
}

/*
 * Environment Variables:
 *
 * RUNTIME_DISCOVER
 *   - Set to "true" to enable class discovery mode (scans all classes, writes to file, then exits)
 *
 * RUNTIME_DISCOVER_RESULT
 *   - File path for reading/writing the list of classes to track
 */
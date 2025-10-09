//===--- ClassDiscovery.mm - Class Discovery Implementation ---------------===//
//
// Discovers app classes and pre-populates shared memory tracker
//
//===----------------------------------------------------------------------===//

#include "ClassDiscovery.h"
#include "ClassTracker.h"
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstring>
#include <atomic>
#include <cstdio>

namespace swift {
namespace runtime_analysis {

// External reference to TrackerData from ClassTracker
extern struct TrackerData {
  static constexpr size_t TABLE_SIZE = 16384;
  struct ClassEntry {
    std::atomic<uint64_t> init_count;
    std::atomic<uint64_t> deinit_count;
    char name[128];
  } entries[TABLE_SIZE];
};

const char* ClassDiscovery::get_bundle_path() {
  static char bundle_path[512] = {0};
  static size_t bundle_path_len = 0;

  if (!bundle_path[0]) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
      const struct mach_header *hdr = _dyld_get_image_header(i);
      if (hdr && hdr->filetype == MH_EXECUTE) {
        const char *path = _dyld_get_image_name(i);
        const char *app = path ? strstr(path, ".app/") : nullptr;
        if (app && (size_t)(app - path + 5) < sizeof(bundle_path)) {
          bundle_path_len = (size_t)(app - path + 5);
          snprintf(bundle_path, sizeof(bundle_path), "%.*s", (int)bundle_path_len, path);
        }
        break;
      }
    }
  }
  return bundle_path[0] ? bundle_path : nullptr;
}

bool ClassDiscovery::is_app_class(const char* image_name) {
  if (!image_name) return false;

  const char* bundle = get_bundle_path();
  if (!bundle) return false;

  size_t bundle_len = strlen(bundle);
  if (strncmp(image_name, bundle, bundle_len) != 0) return false;

  // Exclude Frameworks
  return strstr(image_name, "/Frameworks/") == nullptr;
}

bool ClassDiscovery::discover_and_populate(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: called with tracker=%p\n", (void*)tracker);
  if (!tracker) {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: ERROR - tracker is null\n");
    return false;
  }

  // Check if already populated (first entry has name)
  if (tracker->entries[0].name[0] != '\0') {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: tracker already populated, skipping\n");
    return false; // Already populated
  }

  // Get all classes from runtime
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: calling objc_copyClassList...\n");
  unsigned int num_classes = 0;
  Class *classes = objc_copyClassList(&num_classes);
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: objc_copyClassList returned with %u classes\n", num_classes);

  if (!classes) {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: ERROR - objc_copyClassList failed\n");
    return false;
  }

  size_t entry_index = 0;

  // Iterate through all classes and populate sequentially
  for (unsigned int i = 0; i < num_classes && entry_index < TrackerData::TABLE_SIZE; ++i) {
    Class cls = classes[i];
    if (!cls) continue;

    // Get image name
    const char *image_name = class_getImageName(cls);
    if (!is_app_class(image_name)) {
      continue;
    }

    // Get class name
    const char *class_name = class_getName(cls);
    if (!class_name || !*class_name) {
      continue;
    }

    auto& entry = tracker->entries[entry_index];

    strncpy(entry.name, class_name, sizeof(entry.name) - 1);
    entry.name[sizeof(entry.name) - 1] = '\0';
    entry.init_count.store(0, std::memory_order_release);
    entry.deinit_count.store(0, std::memory_order_release);

    entry_index++;
  }

  free(classes);

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: completed - added %zu app classes\n", entry_index);
  return entry_index > 0;
}

} // namespace runtime_analysis
} // namespace swift

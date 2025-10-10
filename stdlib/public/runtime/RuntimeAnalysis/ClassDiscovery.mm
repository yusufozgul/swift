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
#include <cstdio>

namespace swift {
namespace runtime_analysis {

const char* ClassDiscovery::get_executable_path() {
  static const char* exec_path = nullptr;
  if (exec_path) {
    fprintf(stderr, "[YSWIFT] get_executable_path: returning cached path=%s\n", exec_path);
    return exec_path;
  }

  fprintf(stderr, "[YSWIFT] get_executable_path: searching for main executable\n");
  uint32_t image_count = _dyld_image_count();
  fprintf(stderr, "[YSWIFT] get_executable_path: found %u dyld images\n", image_count);

  for (uint32_t i = 0; i < image_count; i++) {
    const struct mach_header *hdr = _dyld_get_image_header(i);
    const char *image_name = _dyld_get_image_name(i);

    if (hdr && hdr->filetype == MH_EXECUTE) {
      exec_path = image_name;
      fprintf(stderr, "[YSWIFT] get_executable_path: found main executable at index %u: %s\n", i, exec_path);
      break;
    }
  }

  if (!exec_path) {
    fprintf(stderr, "[YSWIFT] get_executable_path: ERROR - main executable not found\n");
  }

  return exec_path;
}

bool ClassDiscovery::discover_and_populate(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: called with tracker=%p\n", (void*)tracker);

  if (!tracker) {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: ERROR - tracker is null\n");
    return false;
  }

  if (tracker->entries[0].name[0] != '\0') {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: tracker already populated (first entry='%s'), skipping\n",
            tracker->entries[0].name);
    return false;
  }

  const char* exec_path = get_executable_path();
  if (!exec_path) {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: ERROR - no executable path found\n");
    return false;
  }

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: querying all registered classes\n");

  unsigned int class_count = 0;
  Class *all_classes = objc_copyClassList(&class_count);

  if (!all_classes) {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: ERROR - objc_copyClassList failed\n");
    return false;
  }

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: found %u total registered classes\n", class_count);

  // Get main executable header for filtering
  const struct mach_header *main_header = nullptr;
  uint32_t image_count = _dyld_image_count();
  for (uint32_t i = 0; i < image_count; i++) {
    const struct mach_header *hdr = _dyld_get_image_header(i);
    if (hdr && hdr->filetype == MH_EXECUTE) {
      main_header = hdr;
      break;
    }
  }

  size_t entry_index = 0;
  size_t filtered_count = 0;
  for (unsigned int i = 0; i < class_count && entry_index < TrackerData::TABLE_SIZE; i++) {
    Class cls = all_classes[i];
    const char* class_name = class_getName(cls);
    if (!class_name) continue;

    // Get the image (binary) that contains this class
    const char* image_name = class_getImageName(cls);
    if (!image_name) continue;

    // Check if class is from main executable
    if (main_header) {
      const struct mach_header *class_header = nullptr;
      for (uint32_t j = 0; j < image_count; j++) {
        if (strcmp(_dyld_get_image_name(j), image_name) == 0) {
          class_header = _dyld_get_image_header(j);
          break;
        }
      }

      // Skip if not from main executable
      if (class_header != main_header) {
        filtered_count++;
        continue;
      }
    }

    auto& entry = tracker->entries[entry_index];
    snprintf(entry.name, sizeof(entry.name), "%s", class_name);
    entry.init_count.store(0, std::memory_order_relaxed);
    entry.deinit_count.store(0, std::memory_order_relaxed);
    entry_index++;
  }

  free(all_classes);

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: filtered out %zu system/framework classes\n", filtered_count);

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: completed - added %zu classes from main executable\n", entry_index);
  return entry_index > 0;
}

} // namespace runtime_analysis
} // namespace swift

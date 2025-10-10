//===--- ClassDiscovery.mm - Class Discovery Implementation ---------------===//
//
// Discovers app classes and pre-populates shared memory tracker
//
//===----------------------------------------------------------------------===//

#include "ClassDiscovery.h"
#include "ClassTracker.h"
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <cstring>
#include <cstdio>

namespace swift {
namespace runtime_analysis {

// Swift type context descriptor structure
struct TypeContextDescriptor {
  uint32_t flags;
  uint32_t parent;
  int32_t name; // relative pointer to name
  // ... other fields
};

// Swift metadata structure
struct Metadata {
  void* kind;
  // ... other fields
};

// External Swift runtime functions
extern "C" {
  // Get type name from metadata
  void swift_getTypeName(const Metadata* type, bool qualified,
                        const char** moduleName, size_t* moduleNameLength,
                        const char** typeName, size_t* typeNameLength);

  // Get metadata from type context descriptor
  const Metadata* swift_getTypeByMangledNode(const void* node, size_t nodeLength);
}

void ClassDiscovery::discover_class_list(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] discover_class_list: called with tracker=%p\n", (void*)tracker);

  // Get executable path using _NSGetExecutablePath
  char executablePathBuf[PATH_MAX];
  uint32_t size = sizeof(executablePathBuf);

  if (_NSGetExecutablePath(executablePathBuf, &size) != 0) {
    fprintf(stderr, "[YSWIFT] discover_class_list: ERROR - failed to get executable path\n");
    return;
  }

  const char *executablePath = strrchr(executablePathBuf, '/');
  executablePath = executablePath ? executablePath + 1 : executablePathBuf;

  char executableName[PATH_MAX];
  snprintf(executableName, sizeof(executableName), "%s.app/%s", executablePath, executablePath);

  fprintf(stderr, "[YSWIFT] discover_class_list: executable name=%s\n", executableName);

  size_t entry_index = 0;
  uint32_t imageCount = _dyld_image_count();

  fprintf(stderr, "[YSWIFT] discover_class_list: scanning %u dyld images for Swift types\n", imageCount);

  for (uint32_t i = 0; i < imageCount && entry_index < TrackerData::TABLE_SIZE; i++) {
    const char *imageName = _dyld_get_image_name(i);

    // Filter to only app's executable
    if (!imageName || !strstr(imageName, executableName)) {
      continue;
    }

    fprintf(stderr, "[YSWIFT] discover_class_list: found app image=%s\n", imageName);

    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
    const struct section_64 *section = getsectbynamefromheader_64(
        header,
        "__TEXT",
        "__swift5_types"
    );

    if (!section) {
      fprintf(stderr, "[YSWIFT] discover_class_list: no __swift5_types section in this image\n");
      continue;
    }

    // Read type metadata pointers
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const int32_t *types = (const int32_t *)(section->addr + slide);
    size_t count = section->size / sizeof(int32_t);

    fprintf(stderr, "[YSWIFT] discover_class_list: found %zu Swift types in __swift5_types section\n", count);

    for (size_t j = 0; j < count && entry_index < TrackerData::TABLE_SIZE; j++) {
      // Resolve relative pointer
      const void *typePtr = (const void *)((uintptr_t)&types[j] + types[j]);
      const TypeContextDescriptor *descriptor = (const TypeContextDescriptor *)typePtr;

      // Extract type kind from flags (lower 5 bits)
      uint8_t kind = descriptor->flags & 0x1F;

      // 0 = class, 1 = struct, 2 = enum
      // Get type metadata to extract the name
      const Metadata* metadata = reinterpret_cast<const Metadata*>(descriptor);

      const char* moduleName = nullptr;
      size_t moduleNameLength = 0;
      const char* typeName = nullptr;
      size_t typeNameLength = 0;

      // Get fully qualified name (module.type)
      swift_getTypeName(metadata, /*qualified=*/true,
                       &moduleName, &moduleNameLength,
                       &typeName, &typeNameLength);

      if (moduleName && typeName) {
        auto& entry = tracker->entries[entry_index];

        // Format as ModuleName.TypeName
        snprintf(entry.name, sizeof(entry.name), "%.*s.%.*s",
                (int)moduleNameLength, moduleName,
                (int)typeNameLength, typeName);

        entry.init_count.store(0, std::memory_order_relaxed);
        entry.deinit_count.store(0, std::memory_order_relaxed);
        entry_index++;

        fprintf(stderr, "[YSWIFT] discover_class_list: added %s (kind=%u)\n", entry.name, kind);
      }
    }
  }

  fprintf(stderr, "[YSWIFT] discover_class_list: completed - added %zu types (classes+structs) to tracker\n", entry_index);
}

bool ClassDiscovery::discover_and_populate(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: called with tracker=%p\n", (void*)tracker);

  if (tracker->entries[0].name[0] != '\0') {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: shared memory loaded\n");
    return true;
  }

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: tracker is empty, returning false for lazy initialization\n");
  return false;
}

} // namespace runtime_analysis
} // namespace swift

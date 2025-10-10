//===--- ClassDiscovery.mm - Class Discovery Implementation ---------------===//
//
// Discovers app classes and pre-populates shared memory tracker
//
//===----------------------------------------------------------------------===//

#include "ClassDiscovery.h"
#include "ClassTracker.h"
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <cstring>
#include <cstdio>

namespace swift {
namespace runtime_analysis {

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

  unsigned int class_count = 0;
  Class *all_classes = objc_copyClassList(&class_count);

  if (!all_classes) {
    fprintf(stderr, "[YSWIFT] discover_class_list: ERROR - objc_copyClassList failed\n");
    return;
  }

  // RAII-style cleanup - automatically frees on function exit
  struct ClassListGuard {
    Class* classes;
    ~ClassListGuard() { if (classes) free(classes); }
  } guard{all_classes};

  fprintf(stderr, "[YSWIFT] discover_class_list: found %u total registered classes\n", class_count);

  size_t entry_index = 0;

  for (unsigned int i = 0; i < class_count && entry_index < TrackerData::TABLE_SIZE; i++) {
    Class cls = all_classes[i];

    const char* imageName = class_getImageName(cls);
    if (!imageName) continue;

    if (strstr(imageName, executableName) != nullptr) {
      const char* className = class_getName(cls);
      if (!className) continue;

      auto& entry = tracker->entries[entry_index];
      snprintf(entry.name, sizeof(entry.name), "%s", className);
      entry.init_count.store(0, std::memory_order_relaxed);
      entry.deinit_count.store(0, std::memory_order_relaxed);

      fprintf(stderr, "[YSWIFT] discover_class_list: added class=%s\n", className);
      entry_index++;
    }
  }

  fprintf(stderr, "[YSWIFT] discover_class_list: completed - added %zu classes to tracker\n", entry_index);
}

bool ClassDiscovery::discover_and_populate(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: called with tracker=%p\n", (void*)tracker);

  if (tracker->entries[0].name[0] != '\0') {
    fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: tracker already populated (first entry='%s'), loading from shared memory\n",
            tracker->entries[0].name);
    return true;
  }

  fprintf(stderr, "[YSWIFT] ClassDiscovery::discover_and_populate: tracker is empty, returning false for lazy initialization\n");
  return false;
}

} // namespace runtime_analysis
} // namespace swift

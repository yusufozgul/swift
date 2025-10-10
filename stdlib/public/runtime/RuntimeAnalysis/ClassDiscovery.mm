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

  // Parallel filtering phase: find matching classes concurrently
  __block std::atomic<size_t> match_count{0};

  // Pre-allocate array for matched classes (worst case: all classes match)
  struct MatchedClass {
    const char* name;
    const char* imageName;
  };
  MatchedClass* matched_classes = (MatchedClass*)calloc(class_count, sizeof(MatchedClass));
  if (!matched_classes) {
    fprintf(stderr, "[YSWIFT] discover_class_list: ERROR - failed to allocate matched_classes array\n");
    return;
  }

  // Capture executableName as const char* for block
  const char* execNameForBlock = executableName;

  // Parallel filtering using GCD
  dispatch_apply(class_count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t i) {
    Class cls = all_classes[i];
    const char* imageName = class_getImageName(cls);

    if (imageName && strstr(imageName, execNameForBlock) != nullptr) {
      const char* className = class_getName(cls);
      if (className) {
        size_t index = match_count.fetch_add(1, std::memory_order_relaxed);
        if (index < TrackerData::TABLE_SIZE) {
          matched_classes[index].name = className;
          matched_classes[index].imageName = imageName;
        }
      }
    }
  });

  // Sequential write phase: populate tracker entries
  size_t final_count = std::min(match_count.load(), (size_t)TrackerData::TABLE_SIZE);
  for (size_t i = 0; i < final_count; i++) {
    auto& entry = tracker->entries[i];
    snprintf(entry.name, sizeof(entry.name), "%s", matched_classes[i].name);
    entry.init_count.store(0, std::memory_order_relaxed);
    entry.deinit_count.store(0, std::memory_order_relaxed);
  }

  free(matched_classes);
  fprintf(stderr, "[YSWIFT] discover_class_list: completed - added %zu classes to tracker\n", final_count);
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

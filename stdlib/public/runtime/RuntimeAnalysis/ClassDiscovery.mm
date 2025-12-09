//===--- ClassDiscovery.mm - Class Discovery Implementation ---------------===//
//
// Discovers app classes and pre-populates shared memory tracker
//
//===----------------------------------------------------------------------===//

#include "ClassDiscovery.h"
#include "ClassTracker.h"
#include "swift/Runtime/Metadata.h"
#include "swift/Runtime/HeapObject.h"
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <cstring>
#include <cstdio>
#include <semaphore.h>
#include <fcntl.h>
#include <errno.h>
#include <os/log.h>

namespace swift {
namespace runtime_analysis {

// Logging subsystem
static os_log_t get_discovery_log() {
  static os_log_t log = os_log_create("com.swift.runtime", "ClassDiscovery");
  return log;
}

// RAII wrapper for cross-process discovery lock
class DiscoveryLock {
  sem_t* lock_;
  bool acquired_;

public:
  DiscoveryLock() : lock_(nullptr), acquired_(false) {
    const char* sem_name = "/swift_class_discovery_lock";
    lock_ = sem_open(sem_name, O_CREAT, 0644, 1);

    if (lock_ == SEM_FAILED) {
      os_log_error(get_discovery_log(), "[YSWIFT] ERROR: failed to open discovery semaphore (errno=%d)", errno);
      return;
    }

    sem_wait(lock_);
    acquired_ = true;
  }

  ~DiscoveryLock() {
    if (acquired_ && lock_ != SEM_FAILED) {
      sem_post(lock_);
    }
  }

  bool is_locked() const { return acquired_; }

  // Non-copyable
  DiscoveryLock(const DiscoveryLock&) = delete;
  DiscoveryLock& operator=(const DiscoveryLock&) = delete;
};

// Check if tracker is already populated by another process
static inline bool is_tracker_populated(TrackerData* tracker) {
  return tracker && tracker->entries[0].name[0] != '\0';
}

void ClassDiscovery::discover_class_list(TrackerData* tracker) {
  // Acquire cross-process lock
  DiscoveryLock lock;

  // Check if another process already populated
  if (is_tracker_populated(tracker)) {
    return;
  }

  // Get executable path using _NSGetExecutablePath
  char executablePathBuf[PATH_MAX];
  uint32_t size = sizeof(executablePathBuf);

  if (_NSGetExecutablePath(executablePathBuf, &size) != 0) {
    os_log_error(get_discovery_log(), "[YSWIFT] ERROR: failed to get executable path");
    return;
  }

  const char *executablePath = strrchr(executablePathBuf, '/');
  executablePath = executablePath ? executablePath + 1 : executablePathBuf;

  char executableName[PATH_MAX];
  snprintf(executableName, sizeof(executableName), "%s.app/%s", executablePath, executablePath);

  unsigned int class_count = 0;
  Class *all_classes = objc_copyClassList(&class_count);

  if (!all_classes) {
    os_log_error(get_discovery_log(), "[YSWIFT] ERROR: objc_copyClassList failed");
    return;
  }

  // RAII-style cleanup - automatically frees on function exit
  struct ClassListGuard {
    Class* classes;
    ~ClassListGuard() { if (classes) free(classes); }
  } guard{all_classes};

  // Parallel filtering phase: find matching classes concurrently
  std::atomic<size_t> match_count_storage{0};
  std::atomic<size_t>* match_count = &match_count_storage;

  // Pre-allocate array for matched classes (worst case: all classes match)
  const char** matched_classes = (const char**)calloc(class_count, sizeof(const char*));
  if (!matched_classes) {
    os_log_error(get_discovery_log(), "[YSWIFT] ERROR: failed to allocate matched_classes array");
    return;
  }

  // RAII-style cleanup for matched_classes
  struct MatchedClassGuard {
    const char** classes;
    ~MatchedClassGuard() { if (classes) free(classes); }
  } matched_guard{matched_classes};

  const char* _executableName = executableName;

  // Parallel filtering using GCD
  dispatch_apply(class_count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t i) {
    Class cls = all_classes[i];
    const char* imageName = class_getImageName(cls);

    if (imageName && strstr(imageName, _executableName) != nullptr) {
      const char* className = class_getName(cls);
      if (className) {
        size_t index = match_count->fetch_add(1, std::memory_order_relaxed);
        if (index < TrackerData::TABLE_SIZE) {
          matched_classes[index] = className;
        }
      }
    }
  });

  // Sequential write phase: populate tracker entries
  size_t final_count = std::min(match_count->load(), (size_t)TrackerData::TABLE_SIZE);
  for (size_t i = 0; i < final_count; i++) {
    auto& entry = tracker->entries[i];
    const char* className = matched_classes[i];

    // Get metadata from class name
    const ClassMetadata* metadata = reinterpret_cast<const ClassMetadata*>(
        objc_getClass(className));

    if (metadata) {
      // Get mangled name for fast lookups
      auto mangledName = swift_getMangledTypeName(metadata);
      snprintf(entry.mangled_name, sizeof(entry.mangled_name), "%s", mangledName.data);

      // Get demangled name for readability
      auto demangledName = swift_getTypeName(metadata, true);
      snprintf(entry.name, sizeof(entry.name), "%s", demangledName.data);
    } else {
      // Fallback: use className for both
      snprintf(entry.name, sizeof(entry.name), "%s", className);
      snprintf(entry.mangled_name, sizeof(entry.mangled_name), "%s", className);
    }

    entry.init_count.store(0, std::memory_order_relaxed);
    entry.deinit_count.store(0, std::memory_order_relaxed);
  }
  os_log_info(get_discovery_log(), "[YSWIFT] Discovered %zu classes (with mangled names)", final_count);
}

bool ClassDiscovery::discover_and_populate(TrackerData* tracker) {
  return is_tracker_populated(tracker);
}

} // namespace runtime_analysis
} // namespace swift

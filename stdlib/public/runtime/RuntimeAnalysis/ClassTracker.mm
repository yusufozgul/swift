//===--- ClassTracker.mm - Class Tracking Implementation ------------------===//
//
// Lock-free tracking using atomic operations and shared memory
//
//===----------------------------------------------------------------------===//

#include "ClassTracker.h"
#include "ClassDiscovery.h"
#include "SharedMemory.h"
#include "swift/Runtime/HeapObject.h"
#include <atomic>
#include <mutex>
#include <unordered_map>
#include <string>
#include <cstdio>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>

namespace swift {
namespace runtime_analysis {

std::atomic<TrackerData*> g_tracker{nullptr};
static std::unordered_map<std::string, size_t>* g_class_index_cache = nullptr;

// Helper: Get class name and find index in cache
// Returns SIZE_MAX if not found
static inline size_t get_class_index(const char* class_name) {
  if (!class_name || !*class_name) {
    fprintf(stderr, "[YSWIFT] get_class_index: invalid class_name\n");
    return SIZE_MAX;
  }

  if (!g_class_index_cache) {
    fprintf(stderr, "[YSWIFT] get_class_index: cache not initialized\n");
    return SIZE_MAX;
  }

  auto it = g_class_index_cache->find(class_name);
  if (it == g_class_index_cache->end()) {
    return SIZE_MAX;
  }

  return it->second;
}

void ClassTracker::build_index_cache(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] build_index_cache: called with tracker=%p\n", (void*)tracker);

  if (!tracker) {
    fprintf(stderr, "[YSWIFT] build_index_cache: ERROR - tracker is null\n");
    return;
  }

  if (!g_class_index_cache) {
    g_class_index_cache = new std::unordered_map<std::string, size_t>();
    fprintf(stderr, "[YSWIFT] build_index_cache: created new cache\n");
  }

  size_t count = 0;
  for (size_t i = 0; i < TrackerData::TABLE_SIZE; ++i) {
    const char* name = tracker->entries[i].name;
    if (name[0] != '\0') {
      (*g_class_index_cache)[std::string(name)] = i;
      count++;
    }
  }
  fprintf(stderr, "[YSWIFT] build_index_cache: completed, cached %zu classes\n", count);
}

void ClassTracker::track_init(const HeapObject* object) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker || !object) {
    return;
  }

  const char* name = object_getClassName((__bridge id)object);
  if (!name) return;

  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].init_count.fetch_add(1, std::memory_order_relaxed);
}

void ClassTracker::track_deinit(const HeapObject* object) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker || !object) {
    return;
  }

  const char* name = object_getClassName((__bridge id)object);
  if (!name) return;

  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].deinit_count.fetch_add(1, std::memory_order_relaxed);
}

} // namespace runtime_analysis
} // namespace swift

__attribute__((constructor))
static void auto_initialize_class_tracker() {
  static const char* env = getenv("SWIFT_CLASS_TRACKING");
  if (!env || env[0] != '1') return;

  fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: starting initialization\n");

  void* mem = swift::runtime_analysis::SharedMemory::get_or_create("/swift_class_tracker", sizeof(swift::runtime_analysis::TrackerData));
  if (!mem) {
    fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: ERROR - failed to get shared memory\n");
    return;
  }
  fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: shared memory obtained at %p\n", mem);

  auto* tracker = static_cast<swift::runtime_analysis::TrackerData*>(mem);
  bool already_populated = swift::runtime_analysis::ClassDiscovery::discover_and_populate(tracker);

  if (already_populated) {
    fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: tracker was already populated, building cache immediately\n");
    swift::runtime_analysis::ClassTracker::build_index_cache(tracker);
    swift::runtime_analysis::g_tracker.store(tracker, std::memory_order_release);
    fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: initialization complete\n");
  } else {
    fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: tracker is empty, scheduling lazy discovery in 15 seconds\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
      fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: lazy discovery starting after 15s delay\n");
      swift::runtime_analysis::ClassDiscovery::discover_class_list(tracker);
      swift::runtime_analysis::ClassTracker::build_index_cache(tracker);
      swift::runtime_analysis::g_tracker.store(tracker, std::memory_order_release);
      fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: lazy discovery complete, tracker activated\n");
    });
  }
}

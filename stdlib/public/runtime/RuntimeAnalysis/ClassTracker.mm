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
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <string>
#include <cstdio>
#include <dispatch/dispatch.h>
#include <objc/runtime.h>

namespace swift {
namespace runtime_analysis {

static std::atomic<TrackerData*> g_tracker{nullptr};
static std::once_flag g_init_flag;
static std::unordered_map<std::string, size_t>* g_class_index_cache = nullptr;
static std::mutex g_cache_mutex;

// Helper: Extract class name from metadata
static inline const char* get_class_name(const HeapMetadata* metadata) {
  if (!metadata) {
    fprintf(stderr, "[YSWIFT] get_class_name: metadata is null\n");
    return nullptr;
  }
  Class cls = reinterpret_cast<Class>(const_cast<HeapMetadata*>(metadata));
  const char* name = class_getName(cls);
  fprintf(stderr, "[YSWIFT] get_class_name: metadata=%p -> name=%s\n", (void*)metadata, name ? name : "(null)");
  return name;
}

// Helper: Get class name and find index in cache
// Returns SIZE_MAX if not found
static inline size_t get_class_index(const char* class_name) {
  if (!class_name || !*class_name) {
    fprintf(stderr, "[YSWIFT] get_class_index: invalid class_name\n");
    return SIZE_MAX;
  }

  std::lock_guard<std::mutex> lock(g_cache_mutex);

  if (!g_class_index_cache) {
    fprintf(stderr, "[YSWIFT] get_class_index: cache not initialized\n");
    return SIZE_MAX;
  }

  auto it = g_class_index_cache->find(class_name);
  if (it == g_class_index_cache->end()) {
    return SIZE_MAX;
  }

  fprintf(stderr, "[YSWIFT] get_class_index: class '%s' found at index %zu\n", class_name, it->second);
  return it->second;
}

void ClassTracker::build_index_cache(TrackerData* tracker) {
  fprintf(stderr, "[YSWIFT] build_index_cache: called with tracker=%p\n", (void*)tracker);

  if (!tracker) {
    fprintf(stderr, "[YSWIFT] build_index_cache: ERROR - tracker is null\n");
    return;
  }

  std::lock_guard<std::mutex> lock(g_cache_mutex);

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
      if (count <= 10) {  // Log first 10 classes
        fprintf(stderr, "[YSWIFT] build_index_cache: added class '%s' at index %zu\n", name, i);
      }
    }
  }
  fprintf(stderr, "[YSWIFT] build_index_cache: completed, cached %zu classes\n", count);
}

void ClassTracker::initialize() {
  fprintf(stderr, "[YSWIFT] ClassTracker::initialize: called\n");

  std::call_once(g_init_flag, []() {
    fprintf(stderr, "[YSWIFT] ClassTracker::initialize: first-time initialization\n");

    void* mem = SharedMemory::get_or_create("/swift_class_tracker", sizeof(TrackerData));
    if (!mem) {
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: ERROR - failed to get shared memory\n");
      return;
    }
    fprintf(stderr, "[YSWIFT] ClassTracker::initialize: shared memory obtained at %p\n", mem);

    auto* tracker = static_cast<TrackerData*>(mem);
    ClassDiscovery::discover_and_populate(tracker);
    build_index_cache(tracker);
    g_tracker.store(tracker, std::memory_order_release);
    fprintf(stderr, "[YSWIFT] ClassTracker::initialize: initialization complete\n");
  });
}

void ClassTracker::track_init(const HeapMetadata* metadata) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    fprintf(stderr, "[YSWIFT] track_init: tracker not initialized\n");
    return;
  }

  const char* name = get_class_name(metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  uint64_t new_count = tracker->entries[idx].init_count.fetch_add(1, std::memory_order_relaxed) + 1;
  fprintf(stderr, "[YSWIFT] track_init: class '%s' init_count=%llu\n", name, new_count);
}

void ClassTracker::track_deinit(const HeapObject* object) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    fprintf(stderr, "[YSWIFT] track_deinit: tracker not initialized\n");
    return;
  }

  const char* name = get_class_name(object->metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  uint64_t new_count = tracker->entries[idx].deinit_count.fetch_add(1, std::memory_order_relaxed) + 1;
  fprintf(stderr, "[YSWIFT] track_deinit: class '%s' deinit_count=%llu\n", name, new_count);
}

} // namespace runtime_analysis
} // namespace swift

__attribute__((constructor))
static void auto_initialize_class_tracker() {
  static const char* env = getenv("SWIFT_CLASS_TRACKING");
  if (!env || env[0] != '1') return;

  fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: starting early initialization\n");
  swift::runtime_analysis::ClassTracker::initialize();
  fprintf(stderr, "[YSWIFT] auto_initialize_class_tracker: done early initialization\n");
}

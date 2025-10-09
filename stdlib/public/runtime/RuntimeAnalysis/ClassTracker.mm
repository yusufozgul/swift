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

namespace swift {
namespace runtime_analysis {

// Hash table entry
struct ClassEntry {
  std::atomic<uint64_t> init_count;
  std::atomic<uint64_t> deinit_count;
  char name[128];
};

// Shared data structure
struct TrackerData {
  static constexpr size_t TABLE_SIZE = 16384;
  ClassEntry entries[TABLE_SIZE];
};

static std::atomic<TrackerData*> g_tracker{nullptr};
static std::once_flag g_init_flag;
static std::unordered_map<std::string, size_t>* g_class_index_cache = nullptr;

// Helper: Extract class name from metadata
static inline const char* get_class_name(const HeapMetadata* metadata) {
  if (!metadata) return nullptr;

  auto descriptor = metadata->getTypeContextDescriptor();
  if (!descriptor) return nullptr;

  return descriptor->Name.get();
}

// Helper: Get class name and find index in cache
// Returns SIZE_MAX if not found
static inline size_t get_class_index(const char* class_name) {
  if (!class_name || !*class_name || !g_class_index_cache) return SIZE_MAX;

  auto it = g_class_index_cache->find(class_name);
  if (it == g_class_index_cache->end()) {
    fprintf(stderr, "[YSWIFT] get_class_index: class '%s' not found in cache\n", class_name);
    return SIZE_MAX; // Not in cache
  }

  fprintf(stderr, "[YSWIFT] get_class_index: class '%s' found at index %zu\n", class_name, it->second);
  return it->second;
}

void ClassTracker::build_index_cache(TrackerData* tracker) {
  if (!tracker) return;

  if (!g_class_index_cache) {
    g_class_index_cache = new std::unordered_map<std::string, size_t>();
  }

  size_t count = 0;
  for (size_t i = 0; i < TrackerData::TABLE_SIZE; ++i) {
    const char* name = tracker->entries[i].name;
    (*g_class_index_cache)[std::string(name)] = i;
    count++;
  }
  fprintf(stderr, "[YSWIFT] build_index_cache: completed, cached %zu classes\n", count);
}

void ClassTracker::initialize() {
  fprintf(stderr, "[YSWIFT] ClassTracker::initialize: starting initialization\n");
  std::call_once(g_init_flag, []() {
    fprintf(stderr, "[YSWIFT] ClassTracker::initialize: inside call_once\n");
    size_t size = sizeof(TrackerData);
    fprintf(stderr, "[YSWIFT] ClassTracker::initialize: TrackerData size=%zu bytes\n", size);

    void* mem = SharedMemory::get_or_create("/swift_class_tracker", size);
    if (mem) {
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: shared memory created at %p\n", mem);
      auto* tracker = static_cast<TrackerData*>(mem);

      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: calling discover_and_populate\n");
      ClassDiscovery::discover_and_populate(tracker);

      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: calling build_index_cache\n");
      build_index_cache(tracker);

      g_tracker.store(tracker, std::memory_order_release);
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: tracker stored in g_tracker\n");
    } else {
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: ERROR - failed to create shared memory\n");
    }
  });
  fprintf(stderr, "[YSWIFT] ClassTracker::initialize: initialization completed\n");
}

void ClassTracker::track_init(const HeapMetadata* metadata) {
  fprintf(stderr, "[YSWIFT] track_init: called with metadata=%p\n", (void*)metadata);
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    fprintf(stderr, "[YSWIFT] track_init: tracker not initialized, calling initialize()\n");
    initialize();
    tracker = g_tracker.load(std::memory_order_acquire);
    if (!tracker) {
      fprintf(stderr, "[YSWIFT] track_init: ERROR - tracker still null after initialization\n");
      return;
    }
    fprintf(stderr, "[YSWIFT] track_init: tracker initialized successfully, proceeding\n");
  } else {
    fprintf(stderr, "[YSWIFT] track_init: tracker already initialized at %p\n", (void*)tracker);
  }

  const char* name = get_class_name(metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].init_count.fetch_add(1, std::memory_order_relaxed);
}

void ClassTracker::track_deinit(const HeapObject* object) {
  fprintf(stderr, "[YSWIFT] track_deinit: called with object=%p\n", (void*)object);
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    fprintf(stderr, "[YSWIFT] track_deinit: tracker is null, skipping\n");
    return;
  }

  const char* name = get_class_name(object->metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].deinit_count.fetch_add(1, std::memory_order_relaxed);
}

} // namespace runtime_analysis
} // namespace swift

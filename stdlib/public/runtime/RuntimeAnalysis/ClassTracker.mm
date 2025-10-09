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
static std::atomic<bool> g_init_started{false};
static std::unordered_map<std::string, size_t>* g_class_index_cache = nullptr;

static inline bool is_tracking_enabled() {
  static const char* env = getenv("SWIFT_CLASS_TRACKING");
  return env && env[0] == '1';
}

// Helper: Extract class name from metadata
static inline const char* get_class_name(const HeapMetadata* metadata) {
  if (!metadata) return nullptr;
  Class cls = reinterpret_cast<Class>(const_cast<HeapMetadata*>(metadata));
  return class_getName(cls);
}

// Helper: Get class name and find index in cache
// Returns SIZE_MAX if not found
static inline size_t get_class_index(const char* class_name) {
  if (!class_name || !*class_name || !g_class_index_cache) return SIZE_MAX;

  auto it = g_class_index_cache->find(class_name);
  if (it == g_class_index_cache->end()) {
    return SIZE_MAX; // Not in cache
  }
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
    void* mem = SharedMemory::get_or_create("/swift_class_tracker", sizeof(TrackerData));
    if (mem) {
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: shared memory created at %p\n", mem);
      auto* tracker = static_cast<TrackerData*>(mem);

      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: calling discover_and_populate\n");
      ClassDiscovery::discover_and_populate(tracker);

      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: calling build_index_cache\n");
      build_index_cache(tracker);

      g_tracker.store(tracker, std::memory_order_release);
    } else {
      fprintf(stderr, "[YSWIFT] ClassTracker::initialize: ERROR - failed to create shared memory\n");
    }
  });
  fprintf(stderr, "[YSWIFT] ClassTracker::initialize: initialization completed\n");
}

void ClassTracker::track_init(const HeapMetadata* metadata) {
  if (!is_tracking_enabled()) return;

  // Fast path: check if tracker is ready
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    // Start initialization asynchronously on first call
    bool expected = false;
    if (g_init_started.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      // We won the race - start initialization in background
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        initialize();
      });
    }
    // Skip tracking this instance - tracker not ready yet
    return;
  }

  const char* name = get_class_name(metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].init_count.fetch_add(1, std::memory_order_relaxed);
}

void ClassTracker::track_deinit(const HeapObject* object) {
  if (!is_tracking_enabled()) return;

  // Fast path: check if tracker is ready
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    // Tracker not ready yet - skip tracking
    return;
  }

  const char* name = get_class_name(object->metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].deinit_count.fetch_add(1, std::memory_order_relaxed);
}

} // namespace runtime_analysis
} // namespace swift

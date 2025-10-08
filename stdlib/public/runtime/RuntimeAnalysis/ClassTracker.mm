//===--- ClassTracker.mm - Class Tracking Implementation ------------------===//
//
// Lock-free tracking using atomic operations and shared memory
//
//===----------------------------------------------------------------------===//

#include "ClassTracker.h"
#include "ClassDiscovery.h"
#include "SharedMemory.h"
#include "../Metadata.h"
#include "../HeapObject.h"
#include <atomic>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <string>

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
static std::unordered_map<std::string, size_t> g_class_index_cache;

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
  if (!class_name || !*class_name) return SIZE_MAX;

  auto it = g_class_index_cache.find(class_name);
  if (it == g_class_index_cache.end()) {
    return SIZE_MAX; // Not in cache
  }

  return it->second;
}

void ClassTracker::build_index_cache(TrackerData* tracker) {
  if (!tracker) return;

  for (size_t i = 0; i < TrackerData::TABLE_SIZE; ++i) {
    const char* name = tracker->entries[i].name;
    g_class_index_cache[std::string(name)] = i;
  }
}

void ClassTracker::initialize() {
  std::call_once(g_init_flag, []() {
    size_t size = sizeof(TrackerData);
    void* mem = SharedMemory::get_or_create("/swift_class_tracker", size);
    if (mem) {
      auto* tracker = static_cast<TrackerData*>(mem);
      
      ClassDiscovery::discover_and_populate(tracker);
      build_index_cache(tracker);

      g_tracker.store(tracker, std::memory_order_release);
    }
  });
}

void ClassTracker::track_init(const HeapMetadata* metadata) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) {
    initialize();
    tracker = g_tracker.load(std::memory_order_acquire);
    if (!tracker) return;
  }

  const char* name = get_class_name(metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].init_count.fetch_add(1, std::memory_order_relaxed);
}

void ClassTracker::track_deinit(const HeapObject* object) {
  auto tracker = g_tracker.load(std::memory_order_acquire);
  if (!tracker) return;

  const char* name = get_class_name(object->metadata);
  size_t idx = get_class_index(name);
  if (idx == SIZE_MAX) return;

  tracker->entries[idx].deinit_count.fetch_add(1, std::memory_order_relaxed);
}

} // namespace runtime_analysis
} // namespace swift

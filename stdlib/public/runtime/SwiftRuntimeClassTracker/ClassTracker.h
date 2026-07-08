#ifndef SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H
#define SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H

#include "swift/ABI/Metadata.h"
#include <atomic>

namespace swift {

// Forward declarations
struct HeapObject;

namespace runtime_class_tracker {

struct ClassEntry {
  std::atomic<uint64_t> init_count;
  std::atomic<uint64_t> deinit_count;
  char name[128];
  char mangled_name[256];
};

struct TrackerData {
  static constexpr size_t TABLE_SIZE = 16384;
  ClassEntry entries[TABLE_SIZE];
};

class ClassTracker {
public:
  static void track_init(const HeapObject* object);
  static void track_deinit(const HeapObject* object);

  static void build_index_cache(TrackerData* tracker);
};

} // namespace runtime_class_tracker
} // namespace swift

#endif // SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H

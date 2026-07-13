#ifndef SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H
#define SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H

#include "swift/ABI/Metadata.h"
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace swift {

struct HeapObject;

namespace runtime_class_tracker {

struct FilterEntry {
  uintptr_t start;
  uintptr_t end;
};

// Flat array in shared memory: [seq, ts, isInit, name(256 bytes)] per event
static constexpr size_t EVENT_FIELDS = 3; // seq, ts, isInit
static constexpr size_t EVENT_NAME_LEN = 256;
static constexpr size_t EVENT_SIZE = EVENT_FIELDS * 8 + EVENT_NAME_LEN; // 280 bytes
static constexpr size_t EVENT_CAPACITY = 1 << 20;

class ClassTracker {
public:
  static void track_init(const HeapObject *object);
  static void track_deinit(const HeapObject *object);
};

} // namespace runtime_class_tracker
} // namespace swift

#endif // SWIFT_RUNTIME_CLASS_TRACKER_CLASS_TRACKER_H

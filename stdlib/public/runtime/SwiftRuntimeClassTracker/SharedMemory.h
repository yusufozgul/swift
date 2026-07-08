#ifndef SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H
#define SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H

#include <stddef.h>
#include <stdint.h>

namespace swift {
namespace runtime_class_tracker {

class SharedMemory {
public:
  static void* load();
};

} // namespace runtime_class_tracker
} // namespace swift

#endif // SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H
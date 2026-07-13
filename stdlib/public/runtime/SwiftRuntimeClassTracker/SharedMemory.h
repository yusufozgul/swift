#ifndef SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H
#define SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H

#include <cstddef>

namespace swift {
namespace runtime_class_tracker {

class SharedMemory {
public:
  static void *load(const char *name, size_t size, bool readonly = false);
};

} // namespace runtime_class_tracker
} // namespace swift

#endif // SWIFT_RUNTIME_CLASS_TRACKER_SHARED_MEMORY_H

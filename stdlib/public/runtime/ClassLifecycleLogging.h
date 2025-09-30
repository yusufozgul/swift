#ifndef SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H
#define SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

#include "swift/Runtime/Metadata.h"
#include "swift/Runtime/HeapObject.h"

namespace swift {

/// Statistics for a single class
struct ClassLifecycleStats {
  unsigned long initCount;
  unsigned long deinitCount;
  bool isImmortal;
  
  ClassLifecycleStats() : initCount(0), deinitCount(0), isImmortal(false) {}
};

/// Log class lifecycle events (initialization and deinitialization)
/// for debugging and monitoring purposes.
///
/// \param object The heap object being logged
/// \param event The lifecycle event ("INIT" or "DEINIT")
void logClassLifecycle(const HeapObject *object, const char* event);

} // namespace swift

#endif // SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

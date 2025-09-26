#ifndef SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H
#define SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

#include "swift/Runtime/Metadata.h"

namespace swift {

/// Statistics for a single class
struct ClassLifecycleStats {
  unsigned long initCount;
  unsigned long deinitCount;
  bool isDiscovered;
  bool isEverUsed;
  
  ClassLifecycleStats() : initCount(0), deinitCount(0), isDiscovered(true), isEverUsed(false) {}
};

/// Log class lifecycle events (initialization and deinitialization)
/// for debugging and monitoring purposes.
///
/// \param metadata The metadata of the class being logged
/// \param event The lifecycle event ("INIT" or "DEINIT")
void logClassLifecycle(const HeapMetadata *metadata, const char* event);

} // namespace swift

#endif // SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

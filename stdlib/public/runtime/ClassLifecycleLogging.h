#ifndef SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H
#define SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

namespace swift {

struct HeapMetadata;

/// Statistics for a single class
struct ClassLifecycleStats {
  unsigned long initCount;
  unsigned long deinitCount;
  
  ClassLifecycleStats() : initCount(0), deinitCount(0) {}
};

/// Log class lifecycle events (initialization and deinitialization)
/// for debugging and monitoring purposes.
///
/// \param metadata The metadata of the class being logged
/// \param event The lifecycle event ("INIT" or "DEINIT")
void logClassLifecycle(const HeapMetadata *metadata, const char* event);

} // namespace swift

#endif // SWIFT_RUNTIME_CLASSLIFECYCLELOGGING_H

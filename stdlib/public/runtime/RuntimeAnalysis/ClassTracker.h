#ifndef SWIFT_RUNTIME_CLASSTRACKER_H
#define SWIFT_RUNTIME_CLASSTRACKER_H

#include "SharedMemory.h"
#include "swift/Runtime/HeapObject.h"
#include <unordered_map>

// =============================================================================
// CLASS LIFECYCLE TRACKING - THREAD SAFETY
// =============================================================================
//
// This module tracks class initialization and deinitialization events.
// All public functions are THREAD-SAFE.
//
// MUTEX ARCHITECTURE:
// - Uses internal std::mutex (classStatsMapMutex) for local stats
// - Coordinates with SharedMemory's pthread_mutex for inter-process sync
// - STRICT lock ordering prevents deadlock
//
// LOCK ORDERING:
//   Level 1: classStatsMapMutex (acquired FIRST, released FIRST)
//   Level 2: sharedMemory->mutex (acquired AFTER Level 1 is released)
//
// IMPLEMENTATION DETAILS:
// - logClassLifecycle updates local stats under Level 1 lock
// - Then releases Level 1 lock completely
// - Then calls SharedMemory functions (which acquire Level 2 lock)
// - This ensures NO nested locking ever occurs
//
// =============================================================================

namespace swift {

/// Log class lifecycle events (initialization and deinitialization)
/// for debugging and monitoring purposes.
///
/// \param object The heap object being logged
/// \param event The lifecycle event ("INIT" or "DEINIT")
void logClassLifecycle(const HeapObject *object, const char* event);

/// Check if tracking has been initialized
/// \returns true if tracking is ready, false otherwise
bool isTrackingInitialized();

/// Force initialization of tracking system
/// This is called automatically by logClassLifecycle but can be called manually
void forceTrackingInitialization();

/// Get a copy of current class statistics
/// \returns Map of class names to their statistics
std::unordered_map<std::string, ClassStats> getClassStats();

} // namespace swift

#endif // SWIFT_RUNTIME_CLASSTRACKER_H
//===--- ClassTracker.h - Class Init/Deinit Tracking -----------------------===//
//
// Lock-free, thread-safe class lifecycle tracking
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H
#define SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H

namespace swift {

// Forward declarations
struct HeapObject;

namespace runtime_analysis {

// Forward declaration
struct TrackerData;

// Thread-safe class lifecycle tracker
class ClassTracker {
public:
  // Record class initialization
  static void track_init(const HeapMetadata* metadata);

  // Record class deinitialization
  static void track_deinit(const HeapObject* object);

  // Initialize tracker (called once)
  static void initialize();

  // Build local index cache from shared memory
  static void build_index_cache(TrackerData* tracker);
};

} // namespace runtime_analysis
} // namespace swift

#endif // SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H

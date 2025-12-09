//===--- ClassTracker.h - Class Init/Deinit Tracking -----------------------===//
//
// Lock-free, thread-safe class lifecycle tracking
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H
#define SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H

#include "swift/ABI/Metadata.h"
#include <atomic>

namespace swift {

// Forward declarations
struct HeapObject;

namespace runtime_analysis {

// Hash table entry
struct ClassEntry {
  std::atomic<uint64_t> init_count;
  std::atomic<uint64_t> deinit_count;
  char name[128];
  char mangled_name[256];
};

// Shared data structure
struct TrackerData {
  static constexpr size_t TABLE_SIZE = 16384;
  ClassEntry entries[TABLE_SIZE];
};

// Thread-safe class lifecycle tracker
class ClassTracker {
public:
  // Record class initialization
  static void track_init(const HeapObject* object);

  // Record class deinitialization
  static void track_deinit(const HeapObject* object);

  // Build local index cache from shared memory
  static void build_index_cache(TrackerData* tracker);
};

} // namespace runtime_analysis
} // namespace swift

#endif // SWIFT_RUNTIME_ANALYSIS_CLASS_TRACKER_H

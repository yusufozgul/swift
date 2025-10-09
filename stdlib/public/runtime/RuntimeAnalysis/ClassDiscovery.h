//===--- ClassDiscovery.h - App Class Discovery ---------------------------===//
//
// Discovers all app classes at runtime and pre-populates shared memory
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_ANALYSIS_CLASS_DISCOVERY_H
#define SWIFT_RUNTIME_ANALYSIS_CLASS_DISCOVERY_H

#include "ClassTracker.h"

namespace swift {
namespace runtime_analysis {

// Class discovery and pre-population
class ClassDiscovery {
public:
  // Check if tracker is already populated
  static bool is_populated(TrackerData* tracker);

  // Load existing data from shared memory (sync, no discovery)
  static void load_existing_data_sync(TrackerData* tracker);

  // Discover and populate asynchronously on main queue
  static void discover_and_populate_async(TrackerData* tracker);

  // Discover all app classes and pre-populate tracker (sync)
  // Returns true if discovery was performed, false if shared memory already populated
  static bool discover_and_populate(TrackerData* tracker);

private:
  // Get main executable path
  static const char* get_executable_path();
};

} // namespace runtime_analysis
} // namespace swift

#endif // SWIFT_RUNTIME_ANALYSIS_CLASS_DISCOVERY_H

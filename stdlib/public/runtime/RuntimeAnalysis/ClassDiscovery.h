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
  // Discover all app classes and pre-populate tracker (sync)
  // Returns true if discovery was performed, false if shared memory already populated
  static bool discover_and_populate(TrackerData* tracker);

  // Discover class list and populate tracker
  static void discover_class_list(TrackerData* tracker);
};

} // namespace runtime_analysis
} // namespace swift

#endif // SWIFT_RUNTIME_ANALYSIS_CLASS_DISCOVERY_H

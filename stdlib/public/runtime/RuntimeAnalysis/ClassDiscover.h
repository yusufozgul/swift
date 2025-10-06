#ifndef SWIFT_RUNTIME_CLASSDISCOVER_H
#define SWIFT_RUNTIME_CLASSDISCOVER_H

#include <string>
#include <vector>

namespace swift {

/// Discover all application classes and optionally save them to a file
/// This is used in discovery mode to identify which classes should be tracked
void discoverAllClasses();

/// Load previously discovered classes from a file
/// \returns Vector of class names to track
std::vector<std::string> loadDiscoveredClasses();

} // namespace swift

#endif // SWIFT_RUNTIME_CLASSDISCOVER_H
#ifndef SWIFT_RUNTIME_SHAREDMEMORY_H
#define SWIFT_RUNTIME_SHAREDMEMORY_H

#include <cstdint>
#include <string>
#include <unordered_map>

namespace swift {

/// Statistics for class lifecycle events
struct ClassStats {
  uint64_t initCount;
  uint64_t deinitCount;
};

/// Initialize shared memory for inter-process communication
void initializeSharedMemory();

/// Parse stats from shared memory into a map
/// \param stats Output map to store the parsed statistics
void parseSharedMemoryStats(std::unordered_map<std::string, ClassStats>& stats);

/// Sync class statistics to shared memory and build index mapping
/// \param classStats Map of class names to their statistics
/// \param classIndexMap Output map for O(1) index lookup
/// \returns Number of classes synced to shared memory
uint32_t syncClassesToSharedMemory(const std::unordered_map<std::string, ClassStats>& classStats,
                                  std::unordered_map<std::string, uint32_t>& classIndexMap);

/// Update statistics for a specific class in shared memory
/// \param className Name of the class
/// \param index Index of the class in shared memory
/// \param stats Updated statistics
void updateSharedMemoryStats(const std::string& className, uint32_t index, const ClassStats& stats);

/// Get direct access to shared memory header (for advanced usage)
/// \returns Pointer to shared memory header or nullptr if not initialized
struct SharedMemoryHeader* getSharedMemory();

} // namespace swift

#endif // SWIFT_RUNTIME_SHAREDMEMORY_H
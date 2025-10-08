//===--- SharedMemory.h - Shared Memory Management -------------------------===//
//
// Thread-safe shared memory for cross-process data sharing
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_RUNTIME_ANALYSIS_SHARED_MEMORY_H
#define SWIFT_RUNTIME_ANALYSIS_SHARED_MEMORY_H

#include <stddef.h>
#include <stdint.h>

namespace swift {
namespace runtime_analysis {

// Shared memory segment manager
class SharedMemory {
public:
  // Get or create shared memory segment
  static void* get_or_create(const char* name, size_t size);

  // Unlink shared memory (cleanup)
  static void unlink(const char* name);

  // Get existing segment (returns nullptr if not exists)
  static void* get(const char* name, size_t size);
};

} // namespace runtime_analysis
} // namespace swift

#endif // SWIFT_RUNTIME_ANALYSIS_SHARED_MEMORY_H

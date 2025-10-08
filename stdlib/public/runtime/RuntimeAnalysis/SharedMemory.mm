//===--- SharedMemory.mm - Shared Memory Implementation -------------------===//
//
// POSIX shared memory implementation
//
//===----------------------------------------------------------------------===//

#include "SharedMemory.h"
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>

namespace swift {
namespace runtime_analysis {

void* SharedMemory::get_or_create(const char* name, size_t size) {
  // Try to open existing
  int fd = shm_open(name, O_RDWR, 0666);
  bool created = false;

  if (fd == -1) {
    // Create new
    fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (fd == -1) return nullptr;
    created = true;
  }

  // Set size if newly created
  if (created) {
    if (ftruncate(fd, size) == -1) {
      close(fd);
      return nullptr;
    }
  }

  // Map to memory
  void* addr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);

  if (addr == MAP_FAILED) return nullptr;

  // Zero-initialize if newly created
  if (created) {
    memset(addr, 0, size);
  }

  return addr;
}

void SharedMemory::unlink(const char* name) {
  shm_unlink(name);
}

void* SharedMemory::get(const char* name, size_t size) {
  int fd = shm_open(name, O_RDWR, 0666);
  if (fd == -1) return nullptr;

  void* addr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);

  return (addr == MAP_FAILED) ? nullptr : addr;
}

} // namespace runtime_analysis
} // namespace swift

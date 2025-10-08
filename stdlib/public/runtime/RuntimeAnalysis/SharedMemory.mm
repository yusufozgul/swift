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
#include <cstdio>
#include <cerrno>

namespace swift {
namespace runtime_analysis {

void* SharedMemory::get_or_create(const char* name, size_t size) {
  fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: called with name='%s', size=%zu\n",
          name ? name : "(null)", size);

  // Try to open existing
  int fd = shm_open(name, O_RDWR, 0666);
  bool created = false;

  if (fd == -1) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: shared memory doesn't exist, creating new\n");
    // Create new
    fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (fd == -1) {
      fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: ERROR - failed to create shared memory (errno=%d)\n", errno);
      return nullptr;
    }
    created = true;
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: created new shared memory with fd=%d\n", fd);
  } else {
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: opened existing shared memory with fd=%d\n", fd);
  }

  // Set size if newly created
  if (created) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: setting size to %zu bytes\n", size);
    if (ftruncate(fd, size) == -1) {
      fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: ERROR - ftruncate failed (errno=%d)\n", errno);
      close(fd);
      return nullptr;
    }
  }

  // Map to memory
  fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: mapping to memory\n");
  void* addr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);

  if (addr == MAP_FAILED) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: ERROR - mmap failed (errno=%d)\n", errno);
    return nullptr;
  }

  fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: mapped at address %p\n", addr);

  // Zero-initialize if newly created
  if (created) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: zero-initializing new memory\n");
    memset(addr, 0, size);
  }

  fprintf(stderr, "[YSWIFT] SharedMemory::get_or_create: returning address %p (created=%d)\n", addr, created);
  return addr;
}

void SharedMemory::unlink(const char* name) {
  fprintf(stderr, "[YSWIFT] SharedMemory::unlink: unlinking '%s'\n", name ? name : "(null)");
  int result = shm_unlink(name);
  if (result == -1) {
    fprintf(stderr, "[YSWIFT] SharedMemory::unlink: ERROR - failed to unlink (errno=%d)\n", errno);
  } else {
    fprintf(stderr, "[YSWIFT] SharedMemory::unlink: successfully unlinked\n");
  }
}

void* SharedMemory::get(const char* name, size_t size) {
  fprintf(stderr, "[YSWIFT] SharedMemory::get: called with name='%s', size=%zu\n",
          name ? name : "(null)", size);

  int fd = shm_open(name, O_RDWR, 0666);
  if (fd == -1) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get: ERROR - failed to open shared memory (errno=%d)\n", errno);
    return nullptr;
  }

  fprintf(stderr, "[YSWIFT] SharedMemory::get: opened shared memory with fd=%d\n", fd);

  void* addr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);

  if (addr == MAP_FAILED) {
    fprintf(stderr, "[YSWIFT] SharedMemory::get: ERROR - mmap failed (errno=%d)\n", errno);
    return nullptr;
  }

  fprintf(stderr, "[YSWIFT] SharedMemory::get: mapped at address %p\n", addr);
  return addr;
}

} // namespace runtime_analysis
} // namespace swift

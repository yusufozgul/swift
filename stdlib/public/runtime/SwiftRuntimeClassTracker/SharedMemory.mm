#include "SharedMemory.h"
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

namespace swift {
namespace runtime_class_tracker {

void *SharedMemory::load(const char *name, size_t size, bool readonly) {
  int fd = shm_open(name, readonly ? O_RDONLY : O_RDWR, 0);
  if (fd == -1)
    return nullptr;

  int prot = readonly ? PROT_READ : PROT_READ | PROT_WRITE;
  void *addr = mmap(nullptr, size, prot, MAP_SHARED, fd, 0);
  close(fd);

  if (addr == MAP_FAILED)
    return nullptr;

  return addr;
}

} // namespace runtime_class_tracker
} // namespace swift

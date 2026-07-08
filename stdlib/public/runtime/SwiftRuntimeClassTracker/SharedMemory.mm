#include "SharedMemory.h"
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>
#include <cerrno>

namespace swift {
namespace runtime_class_tracker {
    void* SharedMemory::load() {
        int fd = shm_open("/swift_class_tracker", O_RDWR, 0666);
        
        if (fd == -1) {
            return nullptr;
        }
        
        void* addr = mmap(nullptr, sizeof(swift::runtime_class_tracker::TrackerData), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);

        if (addr == MAP_FAILED) {
            return nullptr;
        }

        return addr;
    }
} // namespace runtime_class_tracker
} // namespace swift

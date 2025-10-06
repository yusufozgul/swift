#include "SharedMemory.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <cstdio>
#include <cstring>
#include <errno.h>
#include <unordered_map>

using namespace swift;

// Shared memory structure for inter-process communication
constexpr size_t MAX_CLASS_NAME_LENGTH = 256;
constexpr size_t MAX_CLASSES = 10000;

struct SharedMemoryEntry {
  char className[MAX_CLASS_NAME_LENGTH];
  ClassStats stats;
};

constexpr size_t SHARED_MEMORY_SIZE = sizeof(pthread_mutex_t) + sizeof(uint32_t) +
                                      (MAX_CLASSES * sizeof(SharedMemoryEntry));

struct SharedMemoryHeader {
  pthread_mutex_t mutex;
  uint32_t classCount;
  SharedMemoryEntry entries[MAX_CLASSES];
};

static constexpr const char* SHARED_MEMORY_NAME = "/swift_class_lifecycle";

static SharedMemoryHeader* sharedMemory = nullptr;

void swift::initializeSharedMemory() {
  // Try to open existing shared memory first
  int fd = shm_open(SHARED_MEMORY_NAME, O_RDWR, 0666);
  bool isNew = false;

  if (fd < 0) {
    // Create new shared memory if it doesn't exist
    fd = shm_open(SHARED_MEMORY_NAME, O_CREAT | O_RDWR, 0666);
    isNew = true;

    if (fd < 0) {
      fprintf(stderr, "[YSWIFT] Failed to create shared memory: %s\n", strerror(errno));
      return;
    }

    if (ftruncate(fd, SHARED_MEMORY_SIZE) < 0) {
      fprintf(stderr, "[YSWIFT] Failed to set shared memory size: %s\n", strerror(errno));
      close(fd);
      return;
    }
  }

  // Map shared memory
  void *addr = mmap(NULL, SHARED_MEMORY_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);

  if (addr == MAP_FAILED) {
    fprintf(stderr, "[YSWIFT] Failed to map shared memory: %s\n", strerror(errno));
    return;
  }

  sharedMemory = static_cast<SharedMemoryHeader*>(addr);

  // Initialize mutex with process-shared attribute if this is new
  if (isNew) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED);
    pthread_mutex_init(&sharedMemory->mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    sharedMemory->classCount = 0;
    fprintf(stderr, "[YSWIFT] Created new shared memory\n");
  } else {
    fprintf(stderr, "[YSWIFT] Attached to existing shared memory\n");
  }
}

void swift::parseSharedMemoryStats(std::unordered_map<std::string, ClassStats>& stats) {
  if (!sharedMemory) return;

  pthread_mutex_lock(&sharedMemory->mutex);
  for (uint32_t i = 0; i < sharedMemory->classCount && i < MAX_CLASSES; i++) {
    stats[sharedMemory->entries[i].className] = sharedMemory->entries[i].stats;
  }
  pthread_mutex_unlock(&sharedMemory->mutex);
}

uint32_t swift::syncClassesToSharedMemory(const std::unordered_map<std::string, ClassStats>& classStats,
                                         std::unordered_map<std::string, uint32_t>& classIndexMap) {
  if (!sharedMemory) return 0;

  pthread_mutex_lock(&sharedMemory->mutex);
  uint32_t idx = 0;
  for (const auto& entry : classStats) {
    if (idx >= MAX_CLASSES) break;

    // Store class info in shared memory
    strncpy(sharedMemory->entries[idx].className, entry.first.c_str(), MAX_CLASS_NAME_LENGTH - 1);
    sharedMemory->entries[idx].className[MAX_CLASS_NAME_LENGTH - 1] = '\0';
    sharedMemory->entries[idx].stats = entry.second;

    classIndexMap[entry.first] = idx;
    idx++;
  }
  sharedMemory->classCount = idx;
  pthread_mutex_unlock(&sharedMemory->mutex);

  fprintf(stderr, "[YSWIFT] Synced %u classes to shared memory with index mapping\n", idx);
  return idx;
}

void swift::updateSharedMemoryStats(const std::string& className, uint32_t index, const ClassStats& stats) {
  if (!sharedMemory || index >= sharedMemory->classCount) return;

  pthread_mutex_lock(&sharedMemory->mutex);
  sharedMemory->entries[index].stats = stats;
  pthread_mutex_unlock(&sharedMemory->mutex);
}

SharedMemoryHeader* swift::getSharedMemory() {
  return sharedMemory;
}
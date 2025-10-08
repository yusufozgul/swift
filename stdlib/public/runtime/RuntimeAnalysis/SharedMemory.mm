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

// For stat structure used in size check
#include <sys/types.h>

using namespace swift;

constexpr size_t SHARED_MEMORY_SIZE = sizeof(SharedMemoryHeader);

static constexpr const char* SHARED_MEMORY_NAME = "/swift_class_lifecycle";

static SharedMemoryHeader* sharedMemory = nullptr;

// =============================================================================
// MUTEX ARCHITECTURE & LOCK ORDERING
// =============================================================================
//
// This module uses a SINGLE pthread_mutex for ALL shared memory operations.
// The mutex is stored IN the shared memory itself to enable inter-process sync.
//
// CRITICAL RULES:
// 1. NEVER call these functions while holding external locks
// 2. NEVER nest mutex acquisitions
// 3. ALL public functions acquire and release the mutex
// 4. Lock duration is MINIMAL (only critical section)
//
// Lock Ordering (to prevent deadlock):
//   Level 1: ClassTracker/AssetTracker local std::mutex (in-process only)
//   Level 2: SharedMemory pthread_mutex (inter-process)
//
// ALWAYS acquire Level 1 FIRST, release it, THEN acquire Level 2.
// NEVER hold both locks simultaneously.
//
// =============================================================================

void swift::initializeSharedMemory() {
  // Try to create new shared memory with O_EXCL to detect if it already exists
  int fd = shm_open(SHARED_MEMORY_NAME, O_CREAT | O_EXCL | O_RDWR, 0666);
  bool isNew = (fd >= 0);

  if (fd < 0 && errno == EEXIST) {
    // Shared memory already exists, try to open it
    fd = shm_open(SHARED_MEMORY_NAME, O_RDWR, 0666);

    if (fd >= 0) {
      // Check if existing shared memory has the correct size
      struct stat sb;
      if (fstat(fd, &sb) == 0 && (size_t)sb.st_size != SHARED_MEMORY_SIZE) {
        fprintf(stderr, "[YSWIFT] Existing shared memory has wrong size (%lld vs %zu), using unlink/recreate\n",
                sb.st_size, SHARED_MEMORY_SIZE);
        close(fd);

        // Try to recreate - this is safe because only the first process will succeed with O_EXCL
        shm_unlink(SHARED_MEMORY_NAME);
        fd = shm_open(SHARED_MEMORY_NAME, O_CREAT | O_EXCL | O_RDWR, 0666);
        isNew = (fd >= 0);

        if (fd < 0 && errno == EEXIST) {
          // Another process already recreated it, just open it
          fd = shm_open(SHARED_MEMORY_NAME, O_RDWR, 0666);
          isNew = false;
        }
      }
    }
  }

  if (fd < 0) {
    fprintf(stderr, "[YSWIFT] Failed to open/create shared memory: %s\n", strerror(errno));
    return;
  }

  // Set size if this is new
  if (isNew && ftruncate(fd, SHARED_MEMORY_SIZE) < 0) {
    fprintf(stderr, "[YSWIFT] Failed to set shared memory size: %s\n", strerror(errno));
    close(fd);
    return;
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
    sharedMemory->assetCount = 0;
    fprintf(stderr, "[YSWIFT] Created new shared memory\n");
  } else {
    fprintf(stderr, "[YSWIFT] Attached to existing shared memory\n");
  }
}

void swift::parseSharedMemoryStats(std::unordered_map<std::string, ClassStats>& stats) {
  // Early validation (no lock needed)
  if (!sharedMemory) return;

  // Acquire mutex for read operation
  pthread_mutex_lock(&sharedMemory->mutex);

  // Read all entries atomically
  uint32_t count = sharedMemory->classCount;
  if (count > MAX_CLASSES) {
    count = MAX_CLASSES; // Safety cap
  }

  for (uint32_t i = 0; i < count; i++) {
    stats[sharedMemory->entries[i].className] = sharedMemory->entries[i].stats;
  }

  pthread_mutex_unlock(&sharedMemory->mutex);
}

uint32_t swift::syncClassesToSharedMemory(const std::unordered_map<std::string, ClassStats>& classStats,
                                         std::unordered_map<std::string, uint32_t>& classIndexMap) {
  // Early validation
  if (!sharedMemory) return 0;

  // Acquire mutex for write operation
  pthread_mutex_lock(&sharedMemory->mutex);

  uint32_t idx = 0;
  for (const auto& entry : classStats) {
    if (idx >= MAX_CLASSES) {
      fprintf(stderr, "[YSWIFT] WARNING: Reached MAX_CLASSES limit (%zu), truncating\n", MAX_CLASSES);
      break;
    }

    // Store class info in shared memory
    strncpy(sharedMemory->entries[idx].className, entry.first.c_str(), MAX_CLASS_NAME_LENGTH - 1);
    sharedMemory->entries[idx].className[MAX_CLASS_NAME_LENGTH - 1] = '\0';
    sharedMemory->entries[idx].stats = entry.second;

    // Build index map (NOTE: classIndexMap is LOCAL, not in shared memory)
    classIndexMap[entry.first] = idx;
    idx++;
  }

  // Update class count atomically
  sharedMemory->classCount = idx;

  pthread_mutex_unlock(&sharedMemory->mutex);

  fprintf(stderr, "[YSWIFT] Synced %u classes to shared memory with index mapping\n", idx);
  return idx;
}

void swift::updateSharedMemoryStats(const std::string& className, uint32_t index, const ClassStats& stats) {
  // Early validation (no lock needed for nullptr check)
  if (!sharedMemory) return;

  // WARNING: This function should ONLY be called AFTER releasing any local locks
  // to avoid nested locking deadlock.

  pthread_mutex_lock(&sharedMemory->mutex);

  // Bounds check INSIDE mutex to prevent TOCTOU race condition
  // Another process could change classCount between check and write
  if (index >= sharedMemory->classCount || index >= MAX_CLASSES) {
    pthread_mutex_unlock(&sharedMemory->mutex);
    fprintf(stderr, "[YSWIFT] WARNING: Invalid index %u (count=%u, max=%zu) for class %s\n",
            index, sharedMemory->classCount, MAX_CLASSES, className.c_str());
    return;
  }

  // Update stats atomically
  sharedMemory->entries[index].stats = stats;

  pthread_mutex_unlock(&sharedMemory->mutex);
}

SharedMemoryHeader* swift::getSharedMemory() {
  return sharedMemory;
}

void swift::parseSharedMemoryAssetStats(std::unordered_map<std::string, AssetStats>& stats) {
  // Early validation (no lock needed)
  if (!sharedMemory) return;

  // Acquire mutex for read operation
  pthread_mutex_lock(&sharedMemory->mutex);

  // Read all entries atomically
  uint32_t count = sharedMemory->assetCount;
  if (count > MAX_ASSETS) {
    count = MAX_ASSETS; // Safety cap
  }

  for (uint32_t i = 0; i < count; i++) {
    stats[sharedMemory->assetEntries[i].assetName] = sharedMemory->assetEntries[i].stats;
  }

  pthread_mutex_unlock(&sharedMemory->mutex);
}

uint32_t swift::syncAssetsToSharedMemory(const std::unordered_map<std::string, AssetStats>& assetStats,
                                         std::unordered_map<std::string, uint32_t>& assetIndexMap) {
  // Early validation
  if (!sharedMemory) return 0;

  // Acquire mutex for write operation
  pthread_mutex_lock(&sharedMemory->mutex);

  uint32_t idx = 0;
  for (const auto& entry : assetStats) {
    if (idx >= MAX_ASSETS) {
      fprintf(stderr, "[YSWIFT] WARNING: Reached MAX_ASSETS limit (%zu), truncating\n", MAX_ASSETS);
      break;
    }

    // Store asset info in shared memory
    strncpy(sharedMemory->assetEntries[idx].assetName, entry.first.c_str(), MAX_ASSET_NAME_LENGTH - 1);
    sharedMemory->assetEntries[idx].assetName[MAX_ASSET_NAME_LENGTH - 1] = '\0';
    sharedMemory->assetEntries[idx].stats = entry.second;

    // Build index map (NOTE: assetIndexMap is LOCAL, not in shared memory)
    assetIndexMap[entry.first] = idx;
    idx++;
  }

  // Update asset count atomically
  sharedMemory->assetCount = idx;

  pthread_mutex_unlock(&sharedMemory->mutex);

  fprintf(stderr, "[YSWIFT] Synced %u assets to shared memory with index mapping\n", idx);
  return idx;
}

void swift::updateSharedMemoryAssetStats(const std::string& assetName, uint32_t index, const AssetStats& stats) {
  // Early validation (no lock needed for nullptr check)
  if (!sharedMemory) return;

  // WARNING: This function should ONLY be called AFTER releasing any local locks
  // to avoid nested locking deadlock.

  pthread_mutex_lock(&sharedMemory->mutex);

  // Bounds check INSIDE mutex to prevent TOCTOU race condition
  // Another process could change assetCount between check and write
  if (index >= sharedMemory->assetCount || index >= MAX_ASSETS) {
    pthread_mutex_unlock(&sharedMemory->mutex);
    fprintf(stderr, "[YSWIFT] WARNING: Invalid index %u (count=%u, max=%zu) for asset %s\n",
            index, sharedMemory->assetCount, MAX_ASSETS, assetName.c_str());
    return;
  }

  // Update stats atomically
  sharedMemory->assetEntries[index].stats = stats;

  pthread_mutex_unlock(&sharedMemory->mutex);
}
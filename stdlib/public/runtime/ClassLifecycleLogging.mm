#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
#include "swift/Runtime/HeapObject.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <objc/runtime.h>
#include <unordered_map>
#include <vector>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>

using namespace swift;

static void enumerateAllClassesInTarget();
static void ensureTrackingInitialized();

// Shared memory structure for inter-process communication
constexpr size_t MAX_CLASS_NAME_LENGTH = 256;
constexpr size_t MAX_CLASSES = 10000;

struct ClassStats {
  uint64_t initCount;
  uint64_t deinitCount;
};

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

static void initializeSharedMemory() {
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

static inline void parseSharedMemoryStats(std::unordered_map<std::string, ClassStats>& stats) {
  if (!sharedMemory) return;
  
  pthread_mutex_lock(&sharedMemory->mutex);
  for (uint32_t i = 0; i < sharedMemory->classCount && i < MAX_CLASSES; i++) {
    stats[sharedMemory->entries[i].className] = sharedMemory->entries[i].stats;
  }
  pthread_mutex_unlock(&sharedMemory->mutex);
}

namespace {
std::unordered_map<std::string, ClassStats> *classStatsMap = nullptr;
std::unordered_map<std::string, uint32_t> *classIndexMap = nullptr; // Maps class name to shared memory index
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
} // namespace

static void initializeTracking() {
  classStatsMap = new std::unordered_map<std::string, ClassStats>();
  classIndexMap = new std::unordered_map<std::string, uint32_t>();
  classStatsMapMutex = new std::mutex();
  initializeSharedMemory();
  enumerateAllClassesInTarget();
  fprintf(stderr, "[YSWIFT] Tracking initialized\n");
}

void swift::logClassLifecycle(const HeapObject *object, const char *event) {
  if (!object || !event) return;
  if (!trackingInitialized.load(std::memory_order_acquire)) {
    ensureTrackingInitialized();
  }
  
  const HeapMetadata *metadata = object->metadata;
  if (!metadata || metadata->getKind() != MetadataKind::Class) return;
  if (!classStatsMap || !classIndexMap || !sharedMemory) return;
  
  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty()) return;

  // Determine if this is init or deinit
  const bool isInit = (event[0] == 'I');
  const bool isDeinit = (event[0] == 'D');
  if (!isInit && !isDeinit) return;

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  
  // Check if we're tracking this class
  auto statsIt = classStatsMap->find(qualifiedName);
  if (statsIt == classStatsMap->end()) return;
  
  auto indexIt = classIndexMap->find(qualifiedName);
  if (indexIt == classIndexMap->end()) return;
  
  // Update local stats
  if (isInit) {
    statsIt->second.initCount++;
  } else {
    statsIt->second.deinitCount++;
  }
  
  // Update shared memory with O(1) index lookup
  uint32_t index = indexIt->second;
  if (index < sharedMemory->classCount) {
    pthread_mutex_lock(&sharedMemory->mutex);
    sharedMemory->entries[index].stats = statsIt->second;
    pthread_mutex_unlock(&sharedMemory->mutex);
  }
}

static void ensureTrackingInitialized() {
  static std::once_flag initFlag;
  std::call_once(initFlag, []() {
    trackingInitialized.store(true, std::memory_order_release);
    initializeTracking();
  });
}

static bool isAppClass(Class cls) {
  if (!cls) return false;
  const char *imageName = class_getImageName(cls);
  if (!imageName) return false;
  
  static char bundlePath[512] = {0};
  static size_t bundlePathLen = 0;
  if (!bundlePath[0]) {
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
      const struct mach_header *hdr = _dyld_get_image_header(i);
      if (hdr && hdr->filetype == MH_EXECUTE) {
        const char *path = _dyld_get_image_name(i);
        const char *app = path ? strstr(path, ".app/") : nullptr;
        if (app && (app - path + 5) < sizeof(bundlePath)) {
          bundlePathLen = (size_t)(app - path + 5);
          snprintf(bundlePath, sizeof(bundlePath), "%.*s", (int)bundlePathLen, path);
          fprintf(stderr, "[YSWIFT] Main bundle path: %s\n", bundlePath);
        }
        break;
      }
    }
  }
  
  if (!bundlePath[0] || strncmp(imageName, bundlePath, bundlePathLen) != 0) return false;
  // Exclude classes from Frameworks folder
  return strstr(imageName, "/Frameworks/") == nullptr;
}

// Only used on iOS Simulator
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
static void enumerateAllClassesInTarget() {
#else
static void enumerateAllClassesInTarget() __attribute__((unused));
static void enumerateAllClassesInTarget() {
#endif
  if (!classStatsMap || !classStatsMapMutex) return;

  const char *discoverMode = getenv("RUNTIME_DISCOVER");
  const char *classListPath = getenv("RUNTIME_DISCOVER_RESULT");
  bool shouldDiscover = discoverMode && strcmp(discoverMode, "true") == 0;
  
  std::vector<std::string> appClassNames;
  
  if (classListPath) {
    if (shouldDiscover) {
      unsigned int numClasses = 0;
      Class *classes = objc_copyClassList(&numClasses);
      
      if (classes) {
        for (unsigned int i = 0; i < numClasses; i++) {
          if (isAppClass(classes[i])) {
            const char *name = class_getName(classes[i]);
            if (name) appClassNames.push_back(name);
          }
        }
        free(classes);
        
        std::ofstream file(classListPath);
        for (const auto& name : appClassNames) file << name << '\n';
        fprintf(stderr, "[YSWIFT] Discovered %zu classes written to: %s\n", appClassNames.size(), classListPath);
        fprintf(stderr, "[YSWIFT] Discovery completed, exiting application\n");
        exit(0);
      }
    } else {
      std::ifstream file(classListPath);
      std::string line;
      while (std::getline(file, line)) {
        if (!line.empty()) appClassNames.push_back(line);
      }
      fprintf(stderr, "[YSWIFT] Loaded %zu classes from: %s\n", appClassNames.size(), classListPath);
    }
  }
  
  // Only populate classStatsMap if appClassNames is not empty
  if (appClassNames.empty()) {
    fprintf(stderr, "[YSWIFT] No classes to track, skipping initialization\n");
    return;
  }
  
  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  classStatsMap->reserve(appClassNames.size());
  classIndexMap->reserve(appClassNames.size());
  
  // Load existing stats from shared memory first
  std::unordered_map<std::string, ClassStats> existingStats;
  parseSharedMemoryStats(existingStats);
  
  // Initialize local map with existing stats or zeros
  for (const auto& name : appClassNames) {
    auto it = existingStats.find(name);
    (*classStatsMap)[name] = (it != existingStats.end()) ? it->second : ClassStats{0, 0};
  }
  
  // Sync all classes to shared memory and build index map
  if (sharedMemory) {
    pthread_mutex_lock(&sharedMemory->mutex);
    uint32_t idx = 0;
    for (const auto& entry : *classStatsMap) {
      if (idx >= MAX_CLASSES) break;
      
      // Store class info in shared memory
      strncpy(sharedMemory->entries[idx].className, entry.first.c_str(), MAX_CLASS_NAME_LENGTH - 1);
      sharedMemory->entries[idx].className[MAX_CLASS_NAME_LENGTH - 1] = '\0';
      sharedMemory->entries[idx].stats = entry.second;
      
      // Build index mapping for O(1) lookup
      (*classIndexMap)[entry.first] = idx;
      idx++;
    }
    sharedMemory->classCount = idx;
    pthread_mutex_unlock(&sharedMemory->mutex);
    fprintf(stderr, "[YSWIFT] Synced %u classes to shared memory with index mapping\n", idx);
  }
}

/*
 * Environment Variables:
 * 
 * RUNTIME_DISCOVER
 *   - Set to "true" to enable class discovery mode (scans all classes, writes to file, then exits)
 *
 * RUNTIME_DISCOVER_RESULT
 *   - File path for reading/writing the list of classes to track
 *
 * Shared Memory:
 *   - Shared memory name: /swift_class_lifecycle
 *   - shm_unlink /swift_class_lifecycle
 */

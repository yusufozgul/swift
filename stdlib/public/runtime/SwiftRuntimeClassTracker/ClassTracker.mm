#include "ClassTracker.h"
#include "SharedMemory.h"
#include "swift/Runtime/HeapObject.h"
#include "swift/ABI/Metadata.h"

#include <algorithm>
#include <atomic>
#include <mutex>

#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

using namespace swift::runtime_class_tracker;

static constexpr size_t HEADER = 64;

static uint8_t *g_events = nullptr;
static std::atomic<uint64_t> *g_write_idx = nullptr;
static FilterEntry g_filter{};
static bool g_filter_valid = false;
static std::once_flag g_init_flag;

static void load_executable_segments() {
  const struct mach_header *mh = _dyld_get_image_header(0);
  if (!mh)
    return;

  const struct load_command *lc = reinterpret_cast<const struct load_command *>(
      reinterpret_cast<const uint8_t *>(mh) + sizeof(struct mach_header_64));

  uintptr_t minAddr = UINTPTR_MAX;
  uintptr_t maxAddr = 0;

  for (uint32_t i = 0; i < mh->ncmds; i++) {
    if (lc->cmd == LC_SEGMENT_64) {
      auto *seg = reinterpret_cast<const struct segment_command_64 *>(lc);
      if (seg->vmsize > 0) {
        uintptr_t start = reinterpret_cast<uintptr_t>(mh) + seg->vmaddr;
        uintptr_t end = start + seg->vmsize;
        if (start < minAddr)
          minAddr = start;
        if (end > maxAddr)
          maxAddr = end;
      }
    }
    lc = reinterpret_cast<const struct load_command *>(
        reinterpret_cast<const uint8_t *>(lc) + lc->cmdsize);
  }

  if (minAddr < maxAddr) {
    g_filter = {minAddr, maxAddr};
    g_filter_valid = true;
  }
}

static void track(const HeapObject *object, bool isInit) {
  std::call_once(g_init_flag, [] {
    g_events = static_cast<uint8_t *>(SharedMemory::load("/swift_class_tracker_events", HEADER + EVENT_SIZE * EVENT_CAPACITY));
    
    if (g_events)
      g_write_idx = reinterpret_cast<std::atomic<uint64_t> *>(g_events);

    load_executable_segments();
  });

  if (!g_events || !g_filter_valid)
    return;

  auto *typeDescriptor = object->metadata->getTypeContextDescriptor();
  if (!typeDescriptor)
    return;

  uintptr_t ptr = reinterpret_cast<uintptr_t>(typeDescriptor);

  if (ptr < g_filter.start || ptr >= g_filter.end)
    return;

  uint64_t seq = g_write_idx->fetch_add(1, std::memory_order_relaxed);
  uint8_t *eventSlot = g_events + HEADER + (seq % EVENT_CAPACITY) * EVENT_SIZE;

  *reinterpret_cast<uint64_t *>(eventSlot + 0) = seq;
  *reinterpret_cast<uint64_t *>(eventSlot + 8) = mach_approximate_time();
  *reinterpret_cast<uint64_t *>(eventSlot + 16) = isInit ? 1 : 0;

  const char *name = typeDescriptor->Name.get();
  size_t len = __builtin_strnlen(name, EVENT_NAME_LEN - 1);
  __builtin_memcpy(eventSlot + 24, name, len);
  eventSlot[24 + len] = '\0';
}

void swift::runtime_class_tracker::ClassTracker::track_init(const HeapObject *object) {
  track(object, true);
}

void swift::runtime_class_tracker::ClassTracker::track_deinit(const HeapObject *object) {
  track(object, false);
}

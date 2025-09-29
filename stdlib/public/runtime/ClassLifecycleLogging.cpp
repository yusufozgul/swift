#include "ClassLifecycleLogging.h"
#include "swift/Runtime/Metadata.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fstream>
#include <mutex>
#include <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <string>
#include <unordered_map>
#include <unordered_set>

using namespace swift;

static void enumerateAllClassesInTarget();
static void writeClassLifecycleStatisticsNow();

namespace {
std::unordered_map<std::string, ClassLifecycleStats> *classStatsMap = nullptr;
std::unordered_set<std::string> *discoveredClasses = nullptr;
std::mutex *classStatsMapMutex = nullptr;
std::atomic<bool> trackingInitialized{false};
dispatch_queue_t trackingQueue = nullptr;
} // namespace

static void initializeTracking() {
  fprintf(stderr, "[YSWIFT] Initializing tracking on first use\n");
  
  classStatsMap = new std::unordered_map<std::string, ClassLifecycleStats>();
  discoveredClasses = new std::unordered_set<std::string>();
  classStatsMapMutex = new std::mutex();
  trackingQueue = dispatch_queue_create("com.swift.runtime.class_lifecycle_tracking", DISPATCH_QUEUE_SERIAL);

  fprintf(stderr, "[YSWIFT] Enumerating all classes in iOS Simulator target...\n");
  enumerateAllClassesInTarget();

  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, 
                                                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 
                           30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    fprintf(stderr, "[YSWIFT] *** Timer fired, writing stats ***\n");
    writeClassLifecycleStatisticsNow();
  });
  dispatch_resume(timer);
}

void swift::logClassLifecycle(const HeapMetadata *metadata, const char *event) {
  if (!trackingInitialized.load()) {
    if (trackingInitialized.exchange(true)) return;
    initializeTracking();
  }

  if (metadata->getKind() != MetadataKind::Class) return;
  
  // Get the qualified (full module) name from metadata
  std::string qualifiedName = nameForMetadata(metadata, true);
  if (qualifiedName.empty() || !discoveredClasses) return;

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  
  // Check if this qualified name is in our discovered classes
  if (discoveredClasses->find(qualifiedName) == discoveredClasses->end()) {
    return; // Class not found in discovered classes
  }

  auto &stats = (*classStatsMap)[qualifiedName];
  if (event[0] == 'I') { stats.initCount++; }
  else if (event[0] == 'D') { stats.deinitCount++; }
}

static void writeClassLifecycleStatisticsNow() {
  if (!trackingInitialized.load()) {
    return;
  }

  if (!classStatsMap || !classStatsMapMutex || !trackingQueue) {
    return;
  }

  dispatch_sync(trackingQueue, ^{
    std::lock_guard<std::mutex> lock(*classStatsMapMutex);

    if (classStatsMap->empty()) {
      return;
    }

    // Use SIMULATOR_SHARED_RESOURCES_DIRECTORY or default path
    std::string outputPath;
    const char *simulatorSharedDir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
    
    if (simulatorSharedDir && strlen(simulatorSharedDir) > 0) {
      outputPath = std::string(simulatorSharedDir) + "/swift_class_lifecycle_stats.json";
      fprintf(stderr, "[YSWIFT] Using simulator shared resources directory: %s\n", outputPath.c_str());
    } else {
      outputPath = "swift_class_lifecycle_stats.json";
      fprintf(stderr, "[YSWIFT] Using default output path: %s\n", outputPath.c_str());
    }

    @autoreleasepool {
      NSMutableDictionary *jsonDict = [[NSMutableDictionary alloc] init];

      for (const auto &entry : *classStatsMap) {
        const std::string &className = entry.first;
        const ClassLifecycleStats &stats = entry.second;

        NSDictionary *classData = @{
          @"init": @(stats.initCount),
          @"deinit": @(stats.deinitCount)
        };

        NSString *classNameStr = [NSString stringWithUTF8String:className.c_str()];
        [jsonDict setObject:classData forKey:classNameStr];
      }

      NSError *error = nil;
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                         options:NSJSONWritingPrettyPrinted
                                                           error:&error];

      if (jsonData && !error) {
        NSString *outputPathStr = [NSString stringWithUTF8String:outputPath.c_str()];
        BOOL success = [jsonData writeToFile:outputPathStr atomically:YES];
        if (!success) {
          fprintf(stderr, "[YSWIFT] Failed to write JSON file: %s\n", outputPath.c_str());
          return;
        }
      } else {
        fprintf(stderr, "[YSWIFT] JSON serialization error: %s\n", 
                error ? [[error localizedDescription] UTF8String] : "Unknown error");
        return;
      }
    }
    fprintf(stderr,
            "[YSWIFT] *** CLASS LIFECYCLE STATISTICS WRITTEN TO: %s ***\n",
            outputPath.c_str());
  });
}

static bool isAppClass(Class cls) {
  if (!cls)
    return false;

  const char *imageName = class_getImageName(cls);
  if (!imageName)
    return false;

  static const char *appName = getenv("SWIFT_APP_NAME");
  char pattern[256];
  snprintf(pattern, sizeof(pattern), "%s.app/", appName);
  return strstr(imageName, pattern) && !strstr(imageName, "/Frameworks/");
}

static void enumerateAllClassesInTarget() {
  if (!classStatsMap || !classStatsMapMutex)
    return;

  std::unordered_set<std::string> discoveredClassesSet;
  discoveredClassesSet.reserve(1024);
  const char *appName = getenv("SWIFT_APP_NAME");
  fprintf(stderr, "[YSWIFT] Scanning for %s.app classes\n", appName);

  unsigned int numClasses = 0;
  Class *classes = objc_copyClassList(&numClasses);

  if (classes) {
    for (unsigned int i = 0; i < numClasses; i++) {
      Class cls = classes[i];
      const char *className = class_getName(cls);

      if (className && isAppClass(cls)) {
        discoveredClassesSet.emplace(className);
      }
    }
    free(classes);
  }

  std::lock_guard<std::mutex> lock(*classStatsMapMutex);
  classStatsMap->reserve(discoveredClassesSet.size());
  discoveredClasses->reserve(discoveredClassesSet.size());
  
  for (const auto &className : discoveredClassesSet) {
    discoveredClasses->insert(className);
  }

  fprintf(stderr, "[YSWIFT] Found %zu app classes\n", discoveredClasses->size());
  
  // Read previous class count and add current count from JSON
  // Use SIMULATOR_SHARED_RESOURCES_DIRECTORY or default path
  std::string filePath;
  const char *simulatorSharedDir = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY");
  
  if (simulatorSharedDir && strlen(simulatorSharedDir) > 0) {
    filePath = std::string(simulatorSharedDir) + "/swift_class_lifecycle_stats.json";
  } else {
    filePath = "swift_class_lifecycle_stats.json";
  }
  
  if (!filePath.empty()) {
    size_t previousDiscoveredCount = 0;
    std::unordered_map<std::string, ClassLifecycleStats> existingStats;
    
    // Read existing JSON file using NSJSONSerialization
    @autoreleasepool {
      NSString *filePathStr = [NSString stringWithUTF8String:filePath.c_str()];
      NSData *jsonData = [NSData dataWithContentsOfFile:filePathStr];
      
      if (jsonData) {
        NSError *error = nil;
        NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                 options:0
                                                                   error:&error];
        
        if (jsonDict && !error && [jsonDict isKindOfClass:[NSDictionary class]]) {
          for (NSString *className in jsonDict) {
            NSDictionary *classData = jsonDict[className];
            if ([classData isKindOfClass:[NSDictionary class]]) {
              ClassLifecycleStats stats;
              
              NSNumber *initCount = classData[@"init"];
              NSNumber *deinitCount = classData[@"deinit"];
              
              if (initCount && [initCount isKindOfClass:[NSNumber class]]) {
                stats.initCount = [initCount unsignedLongValue];
              }
              
              if (deinitCount && [deinitCount isKindOfClass:[NSNumber class]]) {
                stats.deinitCount = [deinitCount unsignedLongValue];
              }
              
              std::string classNameStr = [className UTF8String];
              existingStats[classNameStr] = stats;
              previousDiscoveredCount++;
            }
          }
          fprintf(stderr, "[YSWIFT] Previous discovered classes from JSON: %zu\n", previousDiscoveredCount);
        } else {
          fprintf(stderr, "[YSWIFT] JSON parsing error: %s\n", 
                  error ? [[error localizedDescription] UTF8String] : "Invalid JSON format");
        }
      } else {
        fprintf(stderr, "[YSWIFT] No previous JSON file found, starting fresh\n");
      }
    }
    
    // Merge existing stats with discovered classes
    {
      std::lock_guard<std::mutex> lock(*classStatsMapMutex);
      for (const auto &entry : existingStats) {
        (*classStatsMap)[entry.first] = entry.second;
      }
    }
    
    size_t totalDiscoveredCount = previousDiscoveredCount + discoveredClasses->size();
    fprintf(stderr, "[YSWIFT] Total discovered classes: %zu (previous: %zu + current session: %zu) - File: %s\n", 
            totalDiscoveredCount, previousDiscoveredCount, discoveredClasses->size(), filePath.c_str());
  } else {
    fprintf(stderr, "[YSWIFT] No output path available\n");
  }
}

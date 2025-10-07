#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <stdint.h>

// clang -Wall -O2 export_runtime_analysis.c -o export_runtime_analysis -pthread

// Constants matching SharedMemory.h
#define MAX_CLASS_NAME_LENGTH 256
#define MAX_CLASSES 10000
#define MAX_ASSET_NAME_LENGTH 512
#define MAX_ASSETS 10000

// Structures matching SharedMemory.h
typedef struct {
    uint64_t initCount;
    uint64_t deinitCount;
} ClassStats;

typedef struct {
    uint64_t accessCount;
} AssetStats;

typedef struct {
    char className[MAX_CLASS_NAME_LENGTH];
    ClassStats stats;
} SharedMemoryEntry;

typedef struct {
    char assetName[MAX_ASSET_NAME_LENGTH];
    AssetStats stats;
} AssetMemoryEntry;

typedef struct {
    pthread_mutex_t mutex;
    uint32_t classCount;
    uint32_t assetCount;
    SharedMemoryEntry entries[MAX_CLASSES];
    AssetMemoryEntry assetEntries[MAX_ASSETS];
} SharedMemoryHeader;

static const char* SHARED_MEMORY_NAME = "/swift_class_lifecycle";

int exportClassesToCSV(const char* outputPath) {
    // Open shared memory
    int fd = shm_open(SHARED_MEMORY_NAME, O_RDONLY, 0666);
    if (fd < 0) {
        fprintf(stderr, "Error: Failed to open shared memory '%s'\n", SHARED_MEMORY_NAME);
        fprintf(stderr, "Make sure your Swift runtime has been running with RuntimeAnalysis enabled.\n");
        return 1;
    }

    // Map shared memory
    size_t shmSize = sizeof(SharedMemoryHeader);
    void* addr = mmap(NULL, shmSize, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);

    if (addr == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to map shared memory\n");
        return 1;
    }

    SharedMemoryHeader* header = (SharedMemoryHeader*)addr;

    // Open output file
    FILE* csvFile = fopen(outputPath, "w");
    if (!csvFile) {
        fprintf(stderr, "Error: Failed to create output file '%s'\n", outputPath);
        munmap(addr, shmSize);
        return 1;
    }

    // Write CSV header
    fprintf(csvFile, "ClassName,InitCount,DeinitCount,ActiveInstances\n");

    // Read and write class entries
    uint32_t classCount = header->classCount < MAX_CLASSES ? header->classCount : MAX_CLASSES;
    printf("Found %u classes in shared memory\n", classCount);

    for (uint32_t i = 0; i < classCount; i++) {
        const char* className = header->entries[i].className;
        uint64_t initCount = header->entries[i].stats.initCount;
        uint64_t deinitCount = header->entries[i].stats.deinitCount;
        int64_t activeInstances = (int64_t)initCount - (int64_t)deinitCount;

        if (strlen(className) > 0) {
            fprintf(csvFile, "%s,%llu,%llu,%lld\n",
                    className, initCount, deinitCount, activeInstances);
        }
    }

    fclose(csvFile);
    munmap(addr, shmSize);

    printf("Successfully exported class statistics to: %s\n", outputPath);
    printf("Total entries: %u\n", classCount);

    return 0;
}

int exportAssetsToCSV(const char* outputPath) {
    // Open shared memory
    int fd = shm_open(SHARED_MEMORY_NAME, O_RDONLY, 0666);
    if (fd < 0) {
        fprintf(stderr, "Error: Failed to open shared memory '%s'\n", SHARED_MEMORY_NAME);
        fprintf(stderr, "Make sure your Swift runtime has been running with RuntimeAnalysis enabled.\n");
        return 1;
    }

    // Map shared memory
    size_t shmSize = sizeof(SharedMemoryHeader);
    void* addr = mmap(NULL, shmSize, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);

    if (addr == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to map shared memory\n");
        return 1;
    }

    SharedMemoryHeader* header = (SharedMemoryHeader*)addr;

    // Open output file
    FILE* csvFile = fopen(outputPath, "w");
    if (!csvFile) {
        fprintf(stderr, "Error: Failed to create output file '%s'\n", outputPath);
        munmap(addr, shmSize);
        return 1;
    }

    // Write CSV header
    fprintf(csvFile, "BundleID,AssetName,AccessCount\n");

    // Read and write asset entries
    uint32_t assetCount = header->assetCount < MAX_ASSETS ? header->assetCount : MAX_ASSETS;
    printf("Found %u assets in shared memory\n", assetCount);

    for (uint32_t i = 0; i < assetCount; i++) {
        const char* assetFullName = header->assetEntries[i].assetName;
        uint64_t accessCount = header->assetEntries[i].stats.accessCount;

        if (strlen(assetFullName) > 0) {
            // Split BundleID:AssetName
            char bundleID[MAX_ASSET_NAME_LENGTH] = "";
            char assetName[MAX_ASSET_NAME_LENGTH] = "";

            const char* colon = strchr(assetFullName, ':');
            if (colon) {
                size_t bundleLen = colon - assetFullName;
                strncpy(bundleID, assetFullName, bundleLen);
                bundleID[bundleLen] = '\0';
                strcpy(assetName, colon + 1);
            } else {
                strcpy(assetName, assetFullName);
            }

            fprintf(csvFile, "\"%s\",\"%s\",%llu\n", bundleID, assetName, accessCount);
        }
    }

    fclose(csvFile);
    munmap(addr, shmSize);

    printf("Successfully exported asset statistics to: %s\n", outputPath);
    printf("Total entries: %u\n", assetCount);

    return 0;
}

void printUsage(const char* programName) {
    printf("Usage: %s [classes|assets] <output_path>\n", programName);
    printf("\n");
    printf("Arguments:\n");
    printf("  classes      Export class lifecycle statistics\n");
    printf("  assets       Export asset access statistics\n");
    printf("  output_path  Path to the output CSV file\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s classes classes_stats.csv\n", programName);
    printf("  %s assets assets_stats.csv\n", programName);
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        printUsage(argv[0]);
        return 1;
    }

    const char* exportType = argv[1];
    const char* outputPath = argv[2];

    if (strcmp(exportType, "classes") == 0) {
        return exportClassesToCSV(outputPath);
    } else if (strcmp(exportType, "assets") == 0) {
        return exportAssetsToCSV(outputPath);
    } else {
        fprintf(stderr, "Error: Invalid export type '%s'\n", exportType);
        fprintf(stderr, "Must be either 'classes' or 'assets'\n");
        printUsage(argv[0]);
        return 1;
    }
}

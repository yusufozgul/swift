#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <stdint.h>
#include <errno.h>

// clang -Wall -O2 export_runtime_analysis.c -o export_runtime_analysis

// Constants matching ClassTracker.mm
#define TABLE_SIZE 16384
#define MAX_CLASS_NAME 128

// Structure matching ClassTracker.mm
typedef struct {
    uint64_t init_count;
    uint64_t deinit_count;
    char name[MAX_CLASS_NAME];
} ClassEntry;

typedef struct {
    ClassEntry entries[TABLE_SIZE];
} TrackerData;

static const char* SHARED_MEMORY_NAME = "/swift_class_tracker";

int exportClassesToCSV(const char* outputPath) {
    // Open shared memory
    int fd = shm_open(SHARED_MEMORY_NAME, O_RDONLY, 0666);
    if (fd < 0) {
        fprintf(stderr, "Error: Failed to open shared memory '%s'\n", SHARED_MEMORY_NAME);
        fprintf(stderr, "Make sure your Swift runtime has been running with RuntimeAnalysis enabled.\n");
        return 1;
    }

    // Map shared memory
    size_t shmSize = sizeof(TrackerData);
    void* addr = mmap(NULL, shmSize, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);

    if (addr == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to map shared memory\n");
        return 1;
    }

    TrackerData* tracker = (TrackerData*)addr;

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
    uint32_t classCount = 0;
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        const char* className = tracker->entries[i].name;

        // Skip empty entries
        if (className[0] == '\0') continue;

        uint64_t initCount = tracker->entries[i].init_count;
        uint64_t deinitCount = tracker->entries[i].deinit_count;
        int64_t activeInstances = (int64_t)initCount - (int64_t)deinitCount;

        fprintf(csvFile, "%s,%llu,%llu,%lld\n",
                className, initCount, deinitCount, activeInstances);
        classCount++;
    }

    fclose(csvFile);
    munmap(addr, shmSize);

    printf("Successfully exported class statistics to: %s\n", outputPath);
    printf("Total entries: %u\n", classCount);

    return 0;
}


int cleanSharedMemory() {
    printf("Cleaning shared memory '%s'...\n", SHARED_MEMORY_NAME);

    if (shm_unlink(SHARED_MEMORY_NAME) == 0) {
        printf("Successfully removed shared memory\n");
        return 0;
    } else {
        if (errno == ENOENT) {
            printf("Shared memory does not exist (already clean)\n");
            return 0;
        } else {
            fprintf(stderr, "Error: Failed to remove shared memory: %s\n", strerror(errno));
            return 1;
        }
    }
}

void printUsage(const char* programName) {
    printf("Usage: %s [classes|clean] <output_path>\n", programName);
    printf("\n");
    printf("Commands:\n");
    printf("  classes      Export class lifecycle statistics to CSV\n");
    printf("  clean        Remove shared memory (cleanup)\n");
    printf("\n");
    printf("Arguments:\n");
    printf("  output_path  Path to the output CSV file (not required for clean)\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s classes classes_stats.csv\n", programName);
    printf("  %s clean\n", programName);
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printUsage(argv[0]);
        return 1;
    }

    const char* command = argv[1];

    // Handle clean command (doesn't need output path)
    if (strcmp(command, "clean") == 0) {
        return cleanSharedMemory();
    }

    // For other commands, require output path
    if (argc < 3) {
        printUsage(argv[0]);
        return 1;
    }

    const char* outputPath = argv[2];

    if (strcmp(command, "classes") == 0) {
        return exportClassesToCSV(outputPath);
    } else {
        fprintf(stderr, "Error: Invalid command '%s'\n", command);
        fprintf(stderr, "Must be either 'classes' or 'clean'\n");
        printUsage(argv[0]);
        return 1;
    }
}

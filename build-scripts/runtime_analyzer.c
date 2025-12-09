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
#include <sys/socket.h>

// clang -Wall -O2 runtime_analyzer.c -o runtime_analyzer

// Constants matching ClassTracker.mm
#define TABLE_SIZE 16384
#define MAX_CLASS_NAME 128
#define MAX_MANGLED_NAME 256

// Structure matching ClassTracker.mm
typedef struct {
    uint64_t init_count;
    uint64_t deinit_count;
    char name[MAX_CLASS_NAME];
    char mangled_name[MAX_MANGLED_NAME];
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
    fprintf(csvFile, "ClassName,MangledName,InitCount,DeinitCount,ActiveInstances\n");

    // Read and write class entries
    uint32_t classCount = 0;
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        const char* className = tracker->entries[i].name;

        // Skip empty entries
        if (className[0] == '\0') continue;

        const char* mangledName = tracker->entries[i].mangled_name;
        uint64_t initCount = tracker->entries[i].init_count;
        uint64_t deinitCount = tracker->entries[i].deinit_count;
        int64_t activeInstances = (int64_t)initCount - (int64_t)deinitCount;

        fprintf(csvFile, "%s,%s,%llu,%llu,%lld\n",
                className, mangledName, initCount, deinitCount, activeInstances);
        classCount++;
    }

    fclose(csvFile);
    munmap(addr, shmSize);

    printf("Successfully exported class statistics to: %s\n", outputPath);
    printf("Total entries: %u\n", classCount);

    return 0;
}


int populateFromBinary(const char* binaryPath) {
    printf("Extracting class names...\n");

    // Resolve to absolute path
    char absolutePath[1024];
    if (realpath(binaryPath, absolutePath) == NULL) {
        fprintf(stderr, "Error: Invalid path '%s'\n", binaryPath);
        return 1;
    }

    // Extract class names using otool (will convert to runtime format later)
    char cmd[1024];
    snprintf(cmd, sizeof(cmd),
        "otool -oV '%s' 2>/dev/null | "
        "grep -E '^[[:space:]]+name[[:space:]]+0x[0-9a-f]+[[:space:]]+_' | "
        "awk '{print $3}' | "
        "grep -E '^(_Tt|_OBJC_CLASS_)' | "
        "sort -u",
        absolutePath);

    char** mangled_swift = malloc(TABLE_SIZE * sizeof(char*));
    char** mangled_objc = malloc(TABLE_SIZE * sizeof(char*));
    int swift_count = 0;
    int objc_count = 0;

    char line[512];

    FILE* otool_pipe = popen(cmd, "r");
    if (!otool_pipe) {
        fprintf(stderr, "Error: Failed to run otool\n");
        return 1;
    }

    while (fgets(line, sizeof(line), otool_pipe)) {
        line[strcspn(line, "\n")] = 0;
        if (strncmp(line, "_Tt", 3) == 0 && swift_count < TABLE_SIZE) {
            mangled_swift[swift_count++] = strdup(line);
        } else if (strncmp(line, "_OBJC_CLASS_$_", 14) == 0 && objc_count < TABLE_SIZE) {
            mangled_objc[objc_count++] = strdup(line + 14);
        }
    }
    pclose(otool_pipe);

    printf("Found %d Swift, %d ObjC classes\n", swift_count, objc_count);

    // Demangle Swift classes
    char** demangled_swift = malloc(TABLE_SIZE * sizeof(char*));
    char** runtime_mangled = malloc(TABLE_SIZE * sizeof(char*));
    int demangled_count = 0;

    if (swift_count > 0) {
        FILE* tmp = fopen("/tmp/mangled.txt", "w");
        if (!tmp) {
            fprintf(stderr, "Error: Failed to create temp file\n");
            return 1;
        }
        for (int i = 0; i < swift_count; i++) fprintf(tmp, "%s\n", mangled_swift[i]);
        fclose(tmp);

        // Demangle and remangle
        if (system("xcrun swift-demangle < /tmp/mangled.txt > /tmp/demangled.txt 2>/dev/null") != 0 ||
            system("xcrun swift-demangle --remangle-new < /tmp/mangled.txt > /tmp/remangled.txt 2>/dev/null") != 0) {
            fprintf(stderr, "Error: swift-demangle failed\n");
            unlink("/tmp/mangled.txt");
            return 1;
        }

        FILE* f_demangled = fopen("/tmp/demangled.txt", "r");
        FILE* f_remangled = fopen("/tmp/remangled.txt", "r");
        if (!f_demangled || !f_remangled) {
            fprintf(stderr, "Error: Failed to open demangle results\n");
            if (f_demangled) fclose(f_demangled);
            if (f_remangled) fclose(f_remangled);
            return 1;
        }

        char d_line[512], r_line[512];
        while (fgets(d_line, sizeof(d_line), f_demangled) &&
               fgets(r_line, sizeof(r_line), f_remangled) &&
               demangled_count < TABLE_SIZE) {
            d_line[strcspn(d_line, "\n")] = 0;
            r_line[strcspn(r_line, "\n")] = 0;
            if (!strlen(d_line) || !strlen(r_line)) continue;

            // Strip symbolic reference prefix ($s) and descriptor suffix (D)
            char* mangled = r_line;
            if (mangled[0] == '$' && mangled[1] == 's') mangled += 2;  // Strip $s
            size_t len = strlen(mangled);
            if (len > 0 && mangled[len - 1] == 'D') mangled[len - 1] = '\0';  // Strip D

            demangled_swift[demangled_count] = strdup(d_line);
            runtime_mangled[demangled_count] = strdup(mangled);
            demangled_count++;
        }

        fclose(f_demangled);
        fclose(f_remangled);
        unlink("/tmp/mangled.txt");
        unlink("/tmp/demangled.txt");
        unlink("/tmp/remangled.txt");
    }

    // Create shared memory
    int fd = shm_open(SHARED_MEMORY_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0 || ftruncate(fd, sizeof(TrackerData)) != 0) return 1;

    TrackerData* tracker = mmap(NULL, sizeof(TrackerData), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (tracker == MAP_FAILED) {
        close(fd);
        return 1;
    }

    memset(tracker, 0, sizeof(TrackerData));

    // Populate entries
    size_t index = 0;
    for (int i = 0; i < demangled_count && index < TABLE_SIZE; i++, index++) {
        snprintf(tracker->entries[index].name, MAX_CLASS_NAME, "%s", demangled_swift[i]);
        snprintf(tracker->entries[index].mangled_name, MAX_MANGLED_NAME, "%s", runtime_mangled[i]);
    }
    for (int i = 0; i < objc_count && index < TABLE_SIZE; i++, index++) {
        snprintf(tracker->entries[index].name, MAX_CLASS_NAME, "%s", mangled_objc[i]);
        snprintf(tracker->entries[index].mangled_name, MAX_MANGLED_NAME, "%s", mangled_objc[i]);
    }

    munmap(tracker, sizeof(TrackerData));
    close(fd);

    // Cleanup
    for (int i = 0; i < swift_count; i++) free(mangled_swift[i]);
    for (int i = 0; i < objc_count; i++) free(mangled_objc[i]);
    for (int i = 0; i < demangled_count; i++) {
        free(demangled_swift[i]);
        free(runtime_mangled[i]);
    }
    free(mangled_swift);
    free(mangled_objc);
    free(demangled_swift);
    free(runtime_mangled);

    printf("Populated %zu classes\n", index);
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
    printf("Usage: %s [populate|classes|clean] <path>\n", programName);
    printf("\n");
    printf("Commands:\n");
    printf("  populate     Populate shared memory from binary (build-time)\n");
    printf("  classes      Export class lifecycle statistics to CSV\n");
    printf("  clean        Remove shared memory (cleanup)\n");
    printf("\n");
    printf("Arguments:\n");
    printf("  path         Binary path (for populate) or CSV output path (for classes)\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s populate /path/to/App.dylib\n", programName);
    printf("  %s classes classes_stats.csv\n", programName);
    printf("  %s clean\n", programName);
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printUsage(argv[0]);
        return 1;
    }

    const char* command = argv[1];

    // Handle clean command (doesn't need path argument)
    if (strcmp(command, "clean") == 0) {
        return cleanSharedMemory();
    }

    // For other commands, require path argument
    if (argc < 3) {
        printUsage(argv[0]);
        return 1;
    }

    const char* path = argv[2];

    if (strcmp(command, "populate") == 0) {
        return populateFromBinary(path);
    } else if (strcmp(command, "classes") == 0) {
        return exportClassesToCSV(path);
    } else {
        fprintf(stderr, "Error: Invalid command '%s'\n", command);
        fprintf(stderr, "Must be 'populate', 'classes', or 'clean'\n");
        printUsage(argv[0]);
        return 1;
    }
}

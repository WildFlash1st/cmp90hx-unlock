// Direct BAR0 access via mmap /sys/bus/pci/devices/0000:01:00.0/resource0
// Usage: bar0 read <bar0_offset_hex>
//        bar0 write <bar0_offset_hex> <value_hex>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        printf("Usage: %s read <offset_hex>\n", argv[0]);
        printf("       %s write <offset_hex> <value_hex>\n", argv[0]);
        return 1;
    }
    int bWrite = (strcmp(argv[1], "write") == 0);
    uint64_t offset = strtoull(argv[2], NULL, 16);
    uint32_t wval = bWrite ? (uint32_t)strtoull(argv[3], NULL, 16) : 0;

    int fd = open("/sys/bus/pci/devices/0000:01:00.0/resource0", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open resource0"); return 1; }

    // Map entire BAR0 (16MB)
    size_t bar_size = 16 * 1024 * 1024;
    volatile uint8_t *bar = mmap(NULL, bar_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bar == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    if (bWrite) {
        *(volatile uint32_t *)(bar + offset) = wval;
        __sync_synchronize();
        uint32_t back = *(volatile uint32_t *)(bar + offset);
        printf("WRITE 0x%08llx = 0x%08x, readback = 0x%08x\n",
               (unsigned long long)offset, wval, back);
    } else {
        uint32_t v = *(volatile uint32_t *)(bar + offset);
        printf("READ 0x%08llx = 0x%08x\n", (unsigned long long)offset, v);
    }

    munmap((void*)bar, bar_size);
    close(fd);
    return 0;
}

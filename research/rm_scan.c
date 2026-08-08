// Scan GR register space for SM issue rate modifier pattern
// On healthy 3080: fmla32=1 (1/2), imla4=1 (1/2), rest FULL (0)
// Packed as 4-bit fields per register (imla0..imla3 in one reg, imla4.. in next?)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <errno.h>

typedef uint32_t NvU32;
typedef int32_t  NvV32;
typedef uint64_t NvU64;
typedef unsigned char NvU8;
typedef NvU32    NvHandle;
typedef uint64_t NvP64;

typedef struct {
    NvHandle hRoot; NvHandle hObjectParent; NvHandle hObjectNew;
    NvV32 hClass; NvP64 pAllocParms; NvP64 pRightsRequested;
    NvU32 paramsSize; NvU32 flags; NvV32 status;
} NVOS64_PARAMETERS;

typedef struct {
    NvHandle hClient; NvHandle hObject; NvV32 cmd; NvU32 flags;
    NvP64 params; NvU32 paramsSize; NvV32 status;
} NVOS54_PARAMETERS;

#define NV01_DEVICE_0 0x00000080U
#define NV20_SUBDEVICE_0 0x00002080U
#define IOCTL_ALLOC   _IOWR(0x46, 0x2b, NVOS64_PARAMETERS)
#define IOCTL_CONTROL _IOWR(0x46, 0x2a, NVOS54_PARAMETERS)

typedef struct {
    NvU8  regOp;
    NvU8  regType;
    NvU8  regStatus;
    NvU8  regQuad;
    NvU32 regGroupMask;
    NvU32 regSubGroupMask;
    NvU32 regOffset;
    NvU32 regValueHi;
    NvU32 regValueLo;
    NvU32 regAndNMaskHi;
    NvU32 regAndNMaskLo;
} NV2080_CTRL_GPU_REG_OP;

#define REG_OP_READ_32 (0x00U)
#define REG_TYPE_GLOBAL (0x00U)

typedef struct {
    NvU32                   hClientTarget;
    NvU32                   hChannelTarget;
    NvU32                   bNonTransactional;
    NvU32                   reserved00[2];
    NvU32                   regOpCount;
    NvP64                   regOps;
    struct { NvU32 flags; NvU32 pad; NvU64 route; } grRouteInfo;
} NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS;

static int alloc_object(int fd, NvHandle hRoot, NvHandle parent, NvV32 cls,
                        NvHandle *obj, const void *params_buf, NvU32 params_size) {
    NVOS64_PARAMETERS p;
    memset(&p, 0, sizeof(p));
    p.hRoot = hRoot;
    p.hObjectParent = parent;
    p.hObjectNew = 0;
    p.hClass = cls;
    p.pAllocParms = (NvP64)(uintptr_t)params_buf;
    p.paramsSize = params_size;
    p.status = 0;
    int rc = ioctl(fd, IOCTL_ALLOC, &p);
    *obj = p.hObjectNew;
    if (rc != 0 || p.status != 0) return -1;
    return 0;
}

// Batch read N registers
static int batch_read(int fd, NvHandle hClient, NvHandle hSubdev,
                      NvU32 *offsets, NvU32 *values, NvU32 n) {
    static NV2080_CTRL_GPU_REG_OP ops[64];
    NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS p;
    memset(&p, 0, sizeof(p));
    memset(ops, 0, sizeof(ops));
    p.regOpCount = n;
    p.regOps = (NvP64)(uintptr_t)ops;
    for (NvU32 i = 0; i < n; i++) {
        ops[i].regOp = REG_OP_READ_32;
        ops[i].regType = REG_TYPE_GLOBAL;
        ops[i].regOffset = offsets[i];
    }
    NVOS54_PARAMETERS ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.hClient = hClient;
    ctrl.hObject = hSubdev;
    ctrl.cmd = 0x20800122U;
    ctrl.params = (NvP64)(uintptr_t)&p;
    ctrl.paramsSize = sizeof(p);
    int rc = ioctl(fd, IOCTL_CONTROL, &ctrl);
    for (NvU32 i = 0; i < n; i++) values[i] = ops[i].regValueLo;
    return (rc == 0 && ctrl.status == 0) ? 0 : -1;
}

int main(void) {
    int fd = open("/dev/nvidiactl", O_RDWR);
    int fd_dev = open("/dev/nvidia0", O_RDWR);
    if (fd < 0 || fd_dev < 0) { perror("open"); return 1; }
    NvHandle hClient = 0, hDevice = 0, hSubdev = 0;
    if (alloc_object(fd, 0, 0, 0x41, &hClient, NULL, 0) != 0) return 1;
    {
        struct {
            NvU32 deviceId; NvU32 hClientShare; NvU32 hTargetClient; NvU32 hTargetDevice;
            NvV32 flags; NvU64 vaSpaceSize; NvU64 vaStartInternal; NvU64 vaLimitInternal;
            NvV32 vaMode;
        } dp;
        memset(&dp, 0, sizeof(dp));
        if (alloc_object(fd, hClient, hClient, NV01_DEVICE_0, &hDevice, &dp, sizeof(dp)) != 0) return 1;
    }
    {
        NvU32 sub = 0;
        if (alloc_object(fd, hClient, hDevice, NV20_SUBDEVICE_0, &hSubdev, &sub, sizeof(sub)) != 0) return 1;
    }

    // Scan GR space. GA102 GR0 at 0x200000-0x400000, GPC blocks.
    // Look for 32-bit value where 4-bit nibbles match 0x0010 pattern (fmla32=1)
    // Candidates: 0x00001000, 0x10000000, 0x00000001 variants, 0x10001000
    const NvU32 candidates[] = {
        0x00001000, 0x10000000, 0x00000001, 0x10001000,
        0x00000010, 0x01000000, 0x00010000, 0x00100000,
        0x10000001, 0x00001001, 0x10001001, 0x10101010,
        0x00101000, 0x00000100,
    };
    NvU32 offsets[64], values[64];
    printf("Scanning 0x200000..0x400000 for issue-rate-like values...\n");
    for (NvU32 base = 0x200000; base < 0x400000; base += 0x100) {
        NvU32 n = 0;
        for (NvU32 i = 0; i < 64; i++) { offsets[n++] = base + i*4; }
        if (batch_read(fd, hClient, hSubdev, offsets, values, n) != 0) continue;
        for (NvU32 i = 0; i < n; i++) {
            for (int c = 0; c < (int)(sizeof(candidates)/sizeof(candidates[0])); c++) {
                if (values[i] == candidates[c]) {
                    printf("  HIT 0x%08x = 0x%08x (cand %s)\n",
                           offsets[i], values[i], "issue-rate?");
                }
            }
        }
    }
    printf("done.\n");
    close(fd); close(fd_dev);
    return 0;
}

// RM GPU_EXEC_REG_OPS (0x20800122) — read/write ANY BAR0 register as root
// Usage: rm_reg read <offset_hex>
//        rm_reg write <offset_hex> <value_hex>
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

// NV2080_CTRL_GPU_REG_OP (32 bytes)
typedef struct {
    NvU8  regOp;            // 0
    NvU8  regType;          // 1
    NvU8  regStatus;        // 2
    NvU8  regQuad;          // 3
    NvU32 regGroupMask;     // 4
    NvU32 regSubGroupMask;  // 8
    NvU32 regOffset;        // 12
    NvU32 regValueHi;       // 16
    NvU32 regValueLo;       // 20
    NvU32 regAndNMaskHi;    // 24
    NvU32 regAndNMaskLo;    // 28
} NV2080_CTRL_GPU_REG_OP;

#define NV2080_CTRL_GPU_REG_OP_READ_32   (0x00U)
#define NV2080_CTRL_GPU_REG_OP_WRITE_32  (0x01U)
#define NV2080_CTRL_GPU_REG_OP_TYPE_GLOBAL (0x00U)

// NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS (regOps is a POINTER)
typedef struct {
    NvU32                   hClientTarget;
    NvU32                   hChannelTarget;
    NvU32                   bNonTransactional;
    NvU32                   reserved00[2];
    NvU32                   regOpCount;
    NvP64                   regOps;    // pointer to NV2080_CTRL_GPU_REG_OP array
    struct {
        NvU32 flags;
        NvU32 pad;
        NvU64 route;
    } grRouteInfo;
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
    if (rc != 0 || p.status != 0) {
        printf("  alloc class=0x%04x -> handle=0x%x rc=%d errno=%d status=0x%x\n",
               cls, *obj, rc, errno, p.status);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        printf("Usage: %s read <offset_hex>\n", argv[0]);
        printf("       %s write <offset_hex> <value_hex>\n", argv[0]);
        return 1;
    }
    int bWrite = (strcmp(argv[1], "write") == 0);
    NvU32 offset = (NvU32)strtoul(argv[2], NULL, 16);
    NvU32 wval = bWrite ? (NvU32)strtoul(argv[3], NULL, 16) : 0;

    int fd = open("/dev/nvidiactl", O_RDWR);
    int fd_dev = open("/dev/nvidia0", O_RDWR);
    if (fd < 0 || fd_dev < 0) { perror("open nvidia devices"); return 1; }

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

    NV2080_CTRL_GPU_REG_OP op;
    memset(&op, 0, sizeof(op));
    op.regOp = bWrite ? NV2080_CTRL_GPU_REG_OP_WRITE_32 : NV2080_CTRL_GPU_REG_OP_READ_32;
    op.regType = NV2080_CTRL_GPU_REG_OP_TYPE_GLOBAL;
    op.regOffset = offset;
    op.regValueLo = wval;

    NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS p;
    memset(&p, 0, sizeof(p));
    p.hClientTarget = 0;
    p.hChannelTarget = 0;
    p.bNonTransactional = 0;
    p.regOpCount = 1;
    p.regOps = (NvP64)(uintptr_t)&op;

    NVOS54_PARAMETERS ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.hClient = hClient;
    ctrl.hObject = hSubdev;
    ctrl.cmd = 0x20800122U; // NV2080_CTRL_CMD_GPU_EXEC_REG_OPS
    ctrl.params = (NvP64)(uintptr_t)&p;
    ctrl.paramsSize = sizeof(p);
    int rc = ioctl(fd, IOCTL_CONTROL, &ctrl);
    printf("EXEC_REG_OPS @ 0x%08x %s: ioctl_rc=%d errno=%d ctrl_status=0x%x\n",
           offset, bWrite ? "WRITE" : "READ", rc, errno, ctrl.status);
    printf("  regStatus=0x%x", op.regStatus);
    if (!bWrite) printf("  value=0x%08x", op.regValueLo);
    printf("\n");
    close(fd); close(fd_dev);
    return 0;
}

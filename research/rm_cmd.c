// Universal RM Control tester — send any NV2080_CTRL command
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
typedef NvU32    NvHandle;
typedef uint64_t NvP64;
typedef uint64_t NvU64;
typedef unsigned char NvU8;

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

// GET_SM_ISSUE_RATE_MODIFIER_PARAMS (32 bytes: route 16 + 9 bytes + pad)
typedef struct {
    NvU32 flags;      // grRouteInfo.flags
    NvU64 route;      // grRouteInfo.route
    NvU8  imla0;
    NvU8  fmla16;
    NvU8  dp;
    NvU8  fmla32;
    NvU8  ffma;
    NvU8  imla1;
    NvU8  imla2;
    NvU8  imla3;
    NvU8  imla4;
    NvU8  pad[7];
} SM_ISSUE_PARAMS;

#define IOCTL_ALLOC   _IOWR(0x46, 0x2b, NVOS64_PARAMETERS)
#define IOCTL_CONTROL _IOWR(0x46, 0x2a, NVOS54_PARAMETERS)

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
    printf("  alloc class=0x%04x -> handle=0x%x rc=%d errno=%d status=0x%x\n",
           cls, *obj, rc, errno, p.status);
    return (rc == 0 && p.status == 0) ? 0 : -1;
}

// Send control command with arbitrary params
static int send_ctrl(int fd, NvHandle hClient, NvHandle hSubdev,
                     NvU32 cmd, void *params, NvU32 psize) {
    NVOS54_PARAMETERS ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.hClient = hClient;
    ctrl.hObject = hSubdev;
    ctrl.cmd = cmd;
    ctrl.params = (NvP64)(uintptr_t)params;
    ctrl.paramsSize = psize;
    int rc = ioctl(fd, IOCTL_CONTROL, &ctrl);
    return rc == 0 ? ctrl.status : -1;
}

int main(int argc, char **argv) {
    int fd = open("/dev/nvidiactl", O_RDWR);
    int fd_dev = open("/dev/nvidia0", O_RDWR);
    if (fd < 0 || fd_dev < 0) { perror("open nvidia devices"); return 1; }

    NvHandle hClient = 0, hDevice = 0, hSubdev = 0;
    if (alloc_object(fd, 0, 0, 0x41, &hClient, NULL, 0) != 0) return 1;
    {
        struct {
            NvU32 deviceId;        // 4
            NvU32 hClientShare;    // 4
            NvU32 hTargetClient;   // 4
            NvU32 hTargetDevice;   // 4
            NvV32 flags;           // 4
            NvU64 vaSpaceSize;     // 8
            NvU64 vaStartInternal; // 8
            NvU64 vaLimitInternal; // 8
            NvV32 vaMode;          // 4
        } dp;
        memset(&dp, 0, sizeof(dp));
        dp.deviceId = 0;
        dp.vaMode = 0;
        if (alloc_object(fd, hClient, hClient, NV01_DEVICE_0, &hDevice, &dp, sizeof(dp)) != 0) return 1;
    }
    {
        NvU32 sub = 0;
        if (alloc_object(fd, hClient, hDevice, NV20_SUBDEVICE_0, &hSubdev, &sub, sizeof(sub)) != 0) return 1;
    }
    printf("Objects OK: client=0x%x dev=0x%x sub=0x%x\n", hClient, hDevice, hSubdev);

    if (argc < 2) {
        printf("Usage: %s <cmd_hex> [params_hex...]\n", argv[0]);
        printf("  e.g.: %s 20801230 00000000 00000000\n", argv[0]);
        return 0;
    }

    NvU32 cmd = (NvU32)strtoul(argv[1], NULL, 16);
    NvU32 params[16] = {0};
    NvU32 psize = 0;
    for (int i = 2; i < argc && i < 18; i++) {
        params[i-2] = (NvU32)strtoul(argv[i], NULL, 16);
        psize = i * 4;
    }
    NvV32 status = send_ctrl(fd, hClient, hSubdev, cmd, params, psize);
    printf("CMD 0x%08X: status=0x%x\n", cmd, status);
    printf("Params: ");
    for (int i = 0; i < psize/4; i++) printf("%08x ", params[i]);
    printf("\n");
    close(fd);
    return 0;
}

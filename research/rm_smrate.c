// Direct RM Control: PERF_RATED_TDP_SET_CONTROL via /dev/nvidiactl
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
typedef NvU32    NvHandle;   // NvHandle is 32-bit in RM API
typedef uint64_t NvP64;
typedef uint64_t NvU64;

// NVOS64_PARAMETERS (RM Alloc) - 48 bytes
typedef struct {
    NvHandle hRoot;             // 4
    NvHandle hObjectParent;     // 4
    NvHandle hObjectNew;        // 4
    NvV32    hClass;            // 4
    NvP64    pAllocParms;       // 8
    NvP64    pRightsRequested;  // 8
    NvU32    paramsSize;        // 4
    NvU32    flags;             // 4
    NvV32    status;            // 4
} NVOS64_PARAMETERS;            // = 44 + align = 48

// NVOS54_PARAMETERS (RM Control) - 32 bytes
typedef struct {
    NvHandle hClient;    // 4
    NvHandle hObject;    // 4
    NvV32    cmd;        // 4
    NvU32    flags;      // 4
    NvP64    params;     // 8
    NvU32    paramsSize; // 4
    NvV32    status;     // 4
} NVOS54_PARAMETERS;     // = 32

// NV2080_CTRL_GR_GET_SM_ISSUE_RATE_MODIFIER_PARAMS
typedef struct {
    NvU32 IMLA0;   // INT/FMA speed select
    NvU32 FMLA16;  // FP16 speed select
} SM_ISSUE_PARAMS;

// RM class IDs
#define NV01_ROOT        0x00000000U
#define NV01_DEVICE_0    0x00000080U
#define NV20_SUBDEVICE_0 0x00002080U

// Commands
#define CMD_GET_SM_ISSUE_RATE 0x20801230U
#define CMD_GET_LEVEL_INFO 0x20802002U

// RATED_TDP values
#define NV2080_CTRL_PERF_RATED_TDP_CLIENT_GPU     0x00000001U
#define NV2080_CTRL_PERF_RATED_TDP_CLIENT_GLOBAL    0x00000002U
#define NV2080_CTRL_PERF_RATED_TDP_ACTION_FORCE_EXCEED 0x00000001U
#define NV2080_CTRL_PERF_RATED_TDP_ACTION_SET     0x00000001U
#define NV2080_CTRL_PERF_RATED_TDP_ACTION_GET     0x00000002U

// ioctl: type=0x46 ('F'), nr=0x2a (RM_CONTROL), 0x2b (RM_ALLOC)
// _IOWR already applies sizeof() to its 3rd arg — pass the TYPE, not sizeof
#define IOCTL_ALLOC   _IOWR(0x46, 0x2b, NVOS64_PARAMETERS)
#define IOCTL_CONTROL _IOWR(0x46, 0x2a, NVOS54_PARAMETERS)

static int alloc_object(int fd, NvHandle hRoot, NvHandle parent, NvV32 cls,
                        NvHandle *obj, const void *params_buf, NvU32 params_size) {
    NVOS64_PARAMETERS p;
    memset(&p, 0, sizeof(p));
    p.hRoot = hRoot;          // client handle
    p.hObjectParent = parent; // parent object
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

int main(void) {
    int fd_ctl = open("/dev/nvidiactl", O_RDWR);
    int fd_dev = open("/dev/nvidia0", O_RDWR);
    if (fd_ctl < 0 || fd_dev < 0) { perror("open nvidia devices"); return 1; }

    NvHandle hClient = 0, hDevice = 0, hSubdev = 0;

    printf("Allocating RM objects:\n");
    // Client (NV01_ROOT_CLIENT 0x41) via nvidiactl
    if (alloc_object(fd_ctl, 0, 0, 0x41, &hClient, NULL, 0) != 0) return 1;
    // Device (NV01_DEVICE_0) via nvidiactl, parent=client
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
        } devparams;
        memset(&devparams, 0, sizeof(devparams));
        devparams.deviceId = 0;
        devparams.vaMode = 0;
        if (alloc_object(fd_ctl, hClient, hClient, NV01_DEVICE_0, &hDevice,
                         &devparams, sizeof(devparams)) != 0) return 1;
    }
    // Subdevice (NV20_SUBDEVICE_0) via nvidiactl, parent=device
    {
        NvU32 subparams = 0; // subDeviceId = 0
        if (alloc_object(fd_ctl, hClient, hDevice, NV20_SUBDEVICE_0, &hSubdev,
                         &subparams, sizeof(subparams)) != 0) return 1;
    }

    printf("\nQuerying SM Issue Rate Modifier...\n");

    // GET_SM_ISSUE_RATE_MODIFIER
    {
        NVOS54_PARAMETERS ctrl;
        SM_ISSUE_PARAMS params;
        memset(&ctrl, 0, sizeof(ctrl));
        memset(&params, 0, sizeof(params));
        ctrl.hClient = hClient;
        ctrl.hObject = hSubdev;
        ctrl.cmd = CMD_GET_SM_ISSUE_RATE;
        ctrl.params = (NvP64)(uintptr_t)&params;
        ctrl.paramsSize = sizeof(params);
        int rc = ioctl(fd_ctl, IOCTL_CONTROL, &ctrl);
        printf("GET_SM_ISSUE_RATE: rc=%d errno=%d status=0x%x\n", rc, errno, ctrl.status);
        printf("  IMLA0 (INT/FMA) = %u (FULL=0, 1/2=1, 1/4=2, 1/8=3, 1/16=4, 1/32=5, 1/64=6)\n", params.IMLA0);
        printf("  FMLA16 (FP16)   = %u (FULL=0, 1/2=1, 1/4=2, 1/8=3, 1/16=4, 1/32=5)\n", params.FMLA16);
    }

close(fd_ctl); close(fd_dev);
    return 0;
}

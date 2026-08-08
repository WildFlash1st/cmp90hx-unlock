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

// NV2080_CTRL_PERF_RATED_TDP_CONTROL_PARAMS
typedef struct {
    NvU32 client;
    NvU32 input;
    NvU32 vPstateType;
} RATED_TDP_PARAMS;

// RM class IDs
#define NV01_ROOT        0x00000000U
#define NV01_DEVICE_0    0x00000080U
#define NV20_SUBDEVICE_0 0x00002080U

// Commands
#define NV2080_CTRL_CMD_PERF_RATED_TDP_GET_CONTROL 0x2080206eU
#define NV2080_CTRL_CMD_PERF_RATED_TDP_SET_CONTROL 0x2080206fU

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

    printf("\nSending PERF commands...\n");

    // First GET_LEVEL_INFO (known-working command) to validate control path
    {
        NVOS54_PARAMETERS ctrl;
        memset(&ctrl, 0, sizeof(ctrl));
        ctrl.hClient = hClient;
        ctrl.hObject = hSubdev;
        ctrl.cmd = 0x20802002; // NV2080_CTRL_CMD_PERF_GET_LEVEL_INFO
        ctrl.params = 0;
        ctrl.paramsSize = 0;
        int rc = ioctl(fd_dev, IOCTL_CONTROL, &ctrl);
        printf("GET_LEVEL_INFO via fd_dev: rc=%d errno=%d status=0x%x\n", rc, errno, ctrl.status);
    }
    {
        NVOS54_PARAMETERS ctrl;
        memset(&ctrl, 0, sizeof(ctrl));
        ctrl.hClient = hClient;
        ctrl.hObject = hSubdev;
        ctrl.cmd = 0x20802002; // NV2080_CTRL_CMD_PERF_GET_LEVEL_INFO
        ctrl.params = 0;
        ctrl.paramsSize = 0;
        int rc = ioctl(fd_ctl, IOCTL_CONTROL, &ctrl);
        printf("GET_LEVEL_INFO via fd_ctl: rc=%d errno=%d status=0x%x\n", rc, errno, ctrl.status);
    }

    // SET control: raise TDP
    {
        NVOS54_PARAMETERS ctrl;
        RATED_TDP_PARAMS params;
        memset(&ctrl, 0, sizeof(ctrl));
        memset(&params, 0, sizeof(params));
        ctrl.hClient = hClient;
        ctrl.hObject = hSubdev;
        ctrl.cmd = NV2080_CTRL_CMD_PERF_RATED_TDP_SET_CONTROL;
        ctrl.params = (NvP64)(uintptr_t)&params;
        ctrl.paramsSize = sizeof(params);
        params.client = NV2080_CTRL_PERF_RATED_TDP_CLIENT_GLOBAL; // 2
        params.input = NV2080_CTRL_PERF_RATED_TDP_ACTION_FORCE_EXCEED; // 1
        int rc = ioctl(fd_ctl, IOCTL_CONTROL, &ctrl);
        printf("SET_CONTROL: rc=%d errno=%d status=0x%x params={client=0x%x input=0x%x vpstate=0x%x}\n",
               rc, errno, ctrl.status, params.client, params.input, params.vPstateType);
    }

    close(fd_ctl); close(fd_dev);
    return 0;
}

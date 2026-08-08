// Definitive SM issue rate query: V2 (index/data list) + V1 + throttle ctrl
// V2 with listSize=0 returns ALL fuse values as (index,data) pairs — no struct ambiguity.
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

// V2 index meanings
static const char *idx_name(int i) {
    switch (i) {
    case 0: return "FMLA16";
    case 1: return "DP";
    case 2: return "FMLA32";
    case 3: return "FFMA";
    case 4: return "IMLA0";
    case 5: return "IMLA1";
    case 6: return "IMLA2";
    case 7: return "IMLA3";
    case 8: return "IMLA4";
    case 9: return "FP16";
    case 10: return "FP32";
    case 11: return "DFMA";
    case 12: return "DMLA";
    default: return "?";
    }
}

static const char *speed_name(NvU32 v) {
    switch (v) {
    case 0: return "FULL";
    case 1: return "1/2";
    case 2: return "1/4";
    case 3: return "1/8";
    case 4: return "1/16";
    case 5: return "1/32";
    case 6: return "1/64";
    default: return "?";
    }
}

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

static NvV32 send_ctrl(int fd, NvHandle hClient, NvHandle hSubdev,
                       NvU32 cmd, void *params, NvU32 psize) {
    NVOS54_PARAMETERS ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.hClient = hClient;
    ctrl.hObject = hSubdev;
    ctrl.cmd = cmd;
    ctrl.params = (NvP64)(uintptr_t)params;
    ctrl.paramsSize = psize;
    int rc = ioctl(fd, IOCTL_CONTROL, &ctrl);
    if (rc != 0) printf("  ioctl rc=%d errno=%d ", rc, errno);
    return ctrl.status;
}

int main(void) {
    int fd = open("/dev/nvidiactl", O_RDWR);
    int fd_dev = open("/dev/nvidia0", O_RDWR);
    if (fd < 0 || fd_dev < 0) { perror("open nvidia devices"); return 1; }

    NvHandle hClient = 0, hDevice = 0, hSubdev = 0;
    printf("Allocating RM objects:\n");
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
    printf("Objects OK: client=0x%x dev=0x%x sub=0x%x\n\n", hClient, hDevice, hSubdev);

    // ---- V2: all fuse values ----
    {
        typedef struct { NvU32 index; NvU32 data; } PAIR;
        typedef struct { NvU32 listSize; PAIR list[0xFF]; } V2PARAMS;
        static V2PARAMS p;
        memset(&p, 0, sizeof(p));
        p.listSize = 0; // return all
        NvV32 st = send_ctrl(fd, hClient, hSubdev, 0x2080123cU, &p, sizeof(p));
        printf("=== V2 GET_SM_ISSUE_RATE_MODIFIER (0x2080123c): status=0x%x, count=%u ===\n",
               st, p.listSize);
        for (NvU32 i = 0; i < p.listSize && i < 0xFF; i++) {
            printf("  %-6s (idx %2u) = %u (%s)\n",
                   idx_name(p.list[i].index), p.list[i].index, p.list[i].data,
                   speed_name(p.list[i].data));
        }
        printf("\n");
    }

    // ---- V1: exact struct (grRouteInfo 16B + 9 bytes) ----
    {
        typedef struct {
            NvU32 flags;      // 0
            NvU32 pad1;       // 4
            NvU64 route;      // 8
            NvU8 imla0;       // 16
            NvU8 fmla16;      // 17
            NvU8 dp;          // 18
            NvU8 fmla32;      // 19
            NvU8 ffma;        // 20
            NvU8 imla1;       // 21
            NvU8 imla2;       // 22
            NvU8 imla3;       // 23
            NvU8 imla4;       // 24
            NvU8 pad2[7];     // 25-31
        } V1PARAMS;           // 32
        static V1PARAMS p;
        memset(&p, 0, sizeof(p));
        NvV32 st = send_ctrl(fd, hClient, hSubdev, 0x20801230U, &p, sizeof(p));
        printf("=== V1 GET_SM_ISSUE_RATE_MODIFIER (0x20801230): status=0x%x ===\n", st);
        printf("  imla0  = %u (%s)\n", p.imla0,  speed_name(p.imla0));
        printf("  fmla16 = %u (%s)\n", p.fmla16, speed_name(p.fmla16));
        printf("  dp     = %u (%s)\n", p.dp,     speed_name(p.dp));
        printf("  fmla32 = %u (%s)\n", p.fmla32, speed_name(p.fmla32));
        printf("  ffma   = %u (%s)\n", p.ffma,   speed_name(p.ffma));
        printf("  imla1  = %u (%s)\n", p.imla1,  speed_name(p.imla1));
        printf("  imla2  = %u (%s)\n", p.imla2,  speed_name(p.imla2));
        printf("  imla3  = %u (%s)\n", p.imla3,  speed_name(p.imla3));
        printf("  imla4  = %u (%s)\n", p.imla4,  speed_name(p.imla4));
        printf("\n");
    }

    // ---- SM ISSUE THROTTLE CTRL (0x2080123d) ----
    {
        typedef struct { NvU32 index; NvU32 data; } PAIR;
        typedef struct { NvU32 listSize; PAIR list[0xFF]; } V2PARAMS;
        static V2PARAMS p;
        memset(&p, 0, sizeof(p));
        p.listSize = 0;
        NvV32 st = send_ctrl(fd, hClient, hSubdev, 0x2080123dU, &p, sizeof(p));
        printf("=== V2 GET_SM_ISSUE_THROTTLE_CTRL (0x2080123d): status=0x%x, count=%u ===\n",
               st, p.listSize);
        for (NvU32 i = 0; i < p.listSize && i < 0xFF; i++) {
            printf("  %-6s (idx %2u) = %u\n", idx_name(p.list[i].index), p.list[i].index, p.list[i].data);
        }
        printf("\n");
    }

    close(fd); close(fd_dev);
    return 0;
}

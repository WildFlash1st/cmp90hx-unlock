// Batch XVE register sweep via NV2080_CTRL_CMD_GPU_EXEC_REG_OPS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <errno.h>

typedef uint32_t NvU32; typedef int32_t NvV32; typedef uint64_t NvU64;
typedef unsigned char NvU8; typedef NvU32 NvHandle; typedef uint64_t NvP64;

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
    NvU8 regOp; NvU8 regType; NvU8 regStatus; NvU8 regQuad;
    NvU32 regGroupMask; NvU32 regSubGroupMask; NvU32 regOffset;
    NvU32 regValueHi; NvU32 regValueLo; NvU32 regAndNMaskHi; NvU32 regAndNMaskLo;
} REGOP;
typedef struct {
    NvU32 hClientTarget; NvU32 hChannelTarget; NvU32 bNonTransactional;
    NvU32 reserved00[2]; NvU32 regOpCount; NvP64 regOps;
    struct { NvU32 flags; NvU32 pad; NvU64 route; } grRouteInfo;
} PARAMS;

static int alloc_object(int fd, NvHandle hRoot, NvHandle parent, NvV32 cls,
                        NvHandle *obj, const void *parms, NvU32 size) {
    NVOS64_PARAMETERS p; memset(&p,0,sizeof(p));
    p.hRoot=hRoot; p.hObjectParent=parent; p.hClass=cls;
    p.pAllocParms=(NvP64)(uintptr_t)parms; p.paramsSize=size;
    int rc=ioctl(fd,IOCTL_ALLOC,&p); *obj=p.hObjectNew;
    if(rc!=0||p.status!=0) return -1;
    return 0;
}

int main(int argc, char **argv) {
    // usage: xve_sweep <listfile: one hex offset per line> [write <val>]
    if(argc<2){ fprintf(stderr,"usage: %s list.txt\n",argv[0]); return 1; }
    FILE *f=fopen(argv[1],"r");
    if(!f){ perror("list"); return 1; }
    static REGOP ops[4096]; NvU32 offs[4096]; int n=0;
    char line[64];
    while(fgets(line,sizeof(line),f)&&n<4096){
        NvU32 a=(NvU32)strtoul(line,NULL,16);
        memset(&ops[n],0,sizeof(REGOP));
        ops[n].regOp=0x00; /* READ_32 */ ops[n].regType=0x00; ops[n].regOffset=a;
        offs[n]=a; n++;
    }
    fclose(f);
    int fd=open("/dev/nvidiactl",O_RDWR); int fdd=open("/dev/nvidia0",O_RDWR);
    if(fd<0||fdd<0){ perror("open"); return 1; }
    NvHandle hClient=0,hDevice=0,hSubdev=0;
    if(alloc_object(fd,0,0,0x41,&hClient,NULL,0)!=0){ puts("alloc client fail"); return 1; }
    struct { NvU32 deviceId,hClientShare,hTargetClient,hTargetDevice; NvV32 flags;
             NvU64 vaSpaceSize,vaStartInternal,vaLimitInternal; NvV32 vaMode; } dp;
    memset(&dp,0,sizeof(dp));
    if(alloc_object(fd,hClient,hClient,NV01_DEVICE_0,&hDevice,&dp,sizeof(dp))!=0){ puts("alloc dev fail"); return 1; }
    NvU32 sub=0;
    if(alloc_object(fd,hClient,hDevice,NV20_SUBDEVICE_0,&hSubdev,&sub,sizeof(sub))!=0){ puts("alloc subdev fail"); return 1; }

    PARAMS p; memset(&p,0,sizeof(p));
    p.regOpCount=n; p.regOps=(NvP64)(uintptr_t)ops;
    NVOS54_PARAMETERS ctrl; memset(&ctrl,0,sizeof(ctrl));
    ctrl.hClient=hClient; ctrl.hObject=hSubdev;
    ctrl.cmd=0x20800122U; ctrl.params=(NvP64)(uintptr_t)&p; ctrl.paramsSize=sizeof(p);
    int rc=ioctl(fd,IOCTL_CONTROL,&ctrl);
    fprintf(stderr,"ioctl rc=%d errno=%d ctrlStatus=0x%x n=%d\n",rc,errno,ctrl.status,n);
    for(int i=0;i<n;i++)
        printf("%08x %08x s=%02x\n",offs[i],ops[i].regValueLo,ops[i].regStatus);
    close(fd); close(fdd);
    return 0;
}

// Quick batch register reader — reads 64 regs at a time, shows non-trivial values
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
typedef struct {
    NvU8 regOp; NvU8 regType; NvU8 regStatus; NvU8 regQuad;
    NvU32 regGroupMask; NvU32 regSubGroupMask; NvU32 regOffset;
    NvU32 regValueHi; NvU32 regValueLo; NvU32 regAndNMaskHi; NvU32 regAndNMaskLo;
} NV2080_CTRL_GPU_REG_OP;
typedef struct {
    NvU32 hClientTarget; NvU32 hChannelTarget; NvU32 bNonTransactional;
    NvU32 reserved00[2]; NvU32 regOpCount; NvP64 regOps;
    struct { NvU32 flags; NvU32 pad; NvU64 route; } grRouteInfo;
} NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS;

#define IOCTL_ALLOC   _IOWR(0x46, 0x2b, NVOS64_PARAMETERS)
#define IOCTL_CONTROL _IOWR(0x46, 0x2a, NVOS54_PARAMETERS)
#define MAX_OPS 64

static int alloc_object(int fd, NvHandle hRoot, NvHandle parent, NvV32 cls,
                        NvHandle *obj, const void *pp, NvU32 ps) {
    NVOS64_PARAMETERS p; memset(&p,0,sizeof(p));
    p.hRoot=hRoot; p.hObjectParent=parent; p.hClass=cls;
    p.pAllocParms=(NvP64)(uintptr_t)pp; p.paramsSize=ps;
    int r=ioctl(fd,IOCTL_ALLOC,&p); *obj=p.hObjectNew;
    return (r==0 && p.status==0)?0:-1;
}

static int batch_read(int fd, NvHandle hClient, NvHandle hSubdev,
                      NvU32 base, NV2080_CTRL_GPU_REG_OP *ops, NvU32 count) {
    NV2080_CTRL_GPU_EXEC_REG_OPS_PARAMS p;
    NVOS54_PARAMETERS ctrl;
    for (NvU32 i=0; i<count; i++) {
        memset(&ops[i],0,sizeof(ops[i]));
        ops[i].regOp=0; ops[i].regType=0; ops[i].regOffset=base+i*4;
    }
    memset(&p,0,sizeof(p)); p.regOpCount=count; p.regOps=(NvP64)(uintptr_t)ops;
    memset(&ctrl,0,sizeof(ctrl));
    ctrl.hClient=hClient; ctrl.hObject=hSubdev; ctrl.cmd=0x20800122U;
    ctrl.params=(NvP64)(uintptr_t)&p; ctrl.paramsSize=sizeof(p);
    ioctl(fd,IOCTL_CONTROL,&ctrl);
    return ctrl.status;
}

int main(int argc, char **argv) {
    if (argc<3) { printf("Usage: %s <start_hex> <end_hex> [label]\n",argv[0]); return 1; }
    NvU32 start=(NvU32)strtoul(argv[1],NULL,16);
    NvU32 end=(NvU32)strtoul(argv[2],NULL,16);
    const char *label = argc>3 ? argv[3] : "";

    int fd=open("/dev/nvidiactl",O_RDWR), fd_dev=open("/dev/nvidia0",O_RDWR);
    if(fd<0||fd_dev<0){perror("open");return 1;}
    NvHandle hC=0,hD=0,hS=0;
    if(alloc_object(fd,0,0,0x41,&hC,NULL,0)!=0) return 1;
    { struct{NvU32 a,b,c,d;NvV32 e;NvU64 f,g,h;NvV32 i;}dp; memset(&dp,0,sizeof(dp));
      if(alloc_object(fd,hC,hC,0x80,&hD,&dp,sizeof(dp))!=0) return 1; }
    { NvU32 s=0; alloc_object(fd,hC,hD,0x2080,&hS,&s,sizeof(s)); }

    NV2080_CTRL_GPU_REG_OP ops[MAX_OPS];
    NvU32 count=0;
    for (NvU32 base=start; base<end; base+=MAX_OPS*4) {
        NvU32 n=MAX_OPS;
        if(base+n*4>end) n=(end-base)/4;
        batch_read(fd,hC,hS,base,ops,n);
        for(NvU32 i=0;i<n;i++){
            NvU32 v=ops[i].regValueLo;
            NvU32 addr=base+i*4;
            if(v!=0 && v!=0xbadfffff && v!=0xffffffff) {
                printf("  0x%08x = 0x%08x\n", addr, v);
                count++;
            }
        }
    }
    printf("[%s] %u non-trivial values in 0x%x-0x%x\n", label, count, start, end);
    close(fd); close(fd_dev);
    return 0;
}

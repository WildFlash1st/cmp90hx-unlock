#!/usr/bin/env python3
import pathlib
import sys

src = sys.argv[1]
p = pathlib.Path(src)
t = p.read_text()

marker = """else
        vgpuHeader->sequence = 0;

    NV_CHECK_OK_OR_RETURN(LEVEL_SILENT, _kgspRpcSanityCheck(pGpu, pKernelGsp, pRpc));"""

rpc_log = """else
        vgpuHeader->sequence = 0;

    // CMP90HX RPC tracer
    NV_PRINTF(LEVEL_ERROR,
        "CMP90HX-RPC: func=0x%x len=%u p0=0x%08x p1=0x%08x p2=0x%08x p3=0x%08x\\n",
        vgpuHeader->function, vgpuHeader->length,
        ((NvU32 *)vgpuHeader->rpc_message_data)[0],
        ((NvU32 *)vgpuHeader->rpc_message_data)[1],
        ((NvU32 *)vgpuHeader->rpc_message_data)[2],
        ((NvU32 *)vgpuHeader->rpc_message_data)[3]);

    NV_CHECK_OK_OR_RETURN(LEVEL_SILENT, _kgspRpcSanityCheck(pGpu, pKernelGsp, pRpc));"""

if marker in t and "CMP90HX-RPC" not in t:
    t = t.replace(marker, rpc_log, 1)
    p.write_text(t)
    print("Added RPC tracer")
else:
    print("RPC tracer already present or pattern not found")

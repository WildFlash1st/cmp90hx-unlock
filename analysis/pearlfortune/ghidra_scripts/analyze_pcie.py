# Ghidra Python script to find PCIe Gen3 references in cmpunlocker-rs
# @category Analysis

from ghidra.program.model.listing import CodeUnit
from ghidra.program.model.symbol import RefType
import re

def search_strings(program, patterns):
    """Search for string patterns in memory"""
    memory = program.getMemory()
    results = []
    
    for pattern in patterns:
        addr = memory.findBytes(program.getMinAddress(), 
                               pattern.encode(), None, True, monitor)
        while addr and not monitor.isCancelled():
            results.append((pattern, addr))
            addr = memory.findBytes(addr.add(1), pattern.encode(), None, True, monitor)
    
    return results

def get_xrefs(program, addr):
    """Get all references to an address"""
    refs = []
    refMgr = program.getReferenceManager()
    for ref in refMgr.getReferencesTo(addr):
        refs.append(ref.getFromAddress())
    return refs

def main():
    print("=" * 60)
    print("PCIe Gen3 Analysis for cmpunlocker-rs")
    print("=" * 60)
    
    # Search patterns
    patterns = [
        "EnablePCIeGen3",
        "NVreg_EnablePCIeGen3",
        "RMPcieLinkSpeed",
        "kbifGetPciLinkMaxSpeedByPciGenInfo",
        "calculatePCIELinkRateMBps",
        "Gen3",
        "pcie",
        "PCIe",
        "LinkSpeed",
        "0x823810",  # PCIE_FUSE
        "0x82057c",  # OPT_GEN23
    ]
    
    print("\n[1] String Search Results:")
    found = search_strings(currentProgram, patterns)
    for pattern, addr in found:
        print(f"  '{pattern}' @ {addr}")
        xrefs = get_xrefs(currentProgram, addr)
        for xref in xrefs[:5]:  # Limit xrefs
            func = getFunctionContaining(xref)
            fname = func.getName() if func else "unknown"
            print(f"    <- {xref} in {fname}")
    
    # Search for register constants
    print("\n[2] Register Constants (little-endian):")
    registers = [
        (0x00823810, "PCIE_FUSE"),
        (0x0082057c, "OPT_GEN23"),
        (0x00088088, "XVE_LnkCap"),
        (0x0008c000, "LINK_CONTROL"),
        (0x0008c040, "LINK_SPEED"),
    ]
    
    memory = currentProgram.getMemory()
    for reg, name in registers:
        # Little-endian 4-byte search
        bytes_le = bytearray([
            reg & 0xFF,
            (reg >> 8) & 0xFF,
            (reg >> 16) & 0xFF,
            (reg >> 24) & 0xFF
        ])
        addr = memory.findBytes(currentProgram.getMinAddress(), bytes(bytes_le), None, True, monitor)
        count = 0
        while addr and count < 5:
            print(f"  {name} (0x{reg:08x}) @ {addr}")
            xrefs = get_xrefs(currentProgram, addr)
            for xref in xrefs[:3]:
                func = getFunctionContaining(xref)
                fname = func.getName() if func else "unknown"
                print(f"    <- {xref} in {fname}")
            count += 1
            addr = memory.findBytes(addr.add(1), bytes(bytes_le), None, True, monitor)
    
    # List functions with "pcie" or "gen3" in name
    print("\n[3] Functions with PCIe-related names:")
    fm = currentProgram.getFunctionManager()
    for func in fm.getFunctions(True):
        name = func.getName().lower()
        if "pcie" in name or "gen3" in name or "link" in name:
            print(f"  {func.getName()} @ {func.getEntryPoint()}")
    
    print("\n" + "=" * 60)
    print("Analysis complete")
    print("=" * 60)

main()

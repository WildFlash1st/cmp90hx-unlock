//Decompile PCIe-related code
//@category Analysis

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.app.decompiler.*;

public class DecompilePCIe extends GhidraScript {
    DecompInterface decompiler;
    
    @Override
    public void run() throws Exception {
        decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        
        Memory memory = currentProgram.getMemory();
        ReferenceManager refMgr = currentProgram.getReferenceManager();
        
        println("============================================================");
        println("DECOMPILING PCIe-RELATED FUNCTIONS");
        println("============================================================");
        
        // 1. Find NVreg_EnablePCIeGen3 
        println("\n[1] FUNCTIONS REFERENCING 'NVreg_EnablePCIeGen3':");
        byte[] pattern = "NVreg_EnablePCIeGen3".getBytes();
        Address addr = memory.findBytes(currentProgram.getMinAddress(), pattern, null, true, monitor);
        
        int count = 0;
        while (addr != null && count < 2) {
            println("\n  String @ " + addr);
            
            for (Reference ref : refMgr.getReferencesTo(addr)) {
                Address from = ref.getFromAddress();
                Function func = getFunctionContaining(from);
                if (func != null) {
                    println("  -> Function: " + func.getName() + " @ " + func.getEntryPoint());
                    decompileFunc(func, 80);
                    break;  // Only first ref
                }
            }
            
            count++;
            addr = memory.findBytes(addr.add(1), pattern, null, true, monitor);
        }
        
        // 2. V67 unlock code around SS0
        println("\n[2] V67 UNLOCK CODE (around SS0=0x82381c reference):");
        byte[] ss0Bytes = new byte[] {(byte)0x1c, (byte)0x38, (byte)0x82, (byte)0x00};
        Address ss0Addr = memory.findBytes(currentProgram.getMinAddress(), ss0Bytes, null, true, monitor);
        if (ss0Addr != null) {
            println("  SS0 constant @ " + ss0Addr);
            Function func = getFunctionContaining(ss0Addr);
            if (func != null) {
                println("  Function: " + func.getName());
                decompileFunc(func, 150);
            } else {
                // Try to find enclosing function
                FunctionManager fm = currentProgram.getFunctionManager();
                for (int offset = 0; offset < 0x500; offset += 0x10) {
                    Address tryAddr = ss0Addr.subtract(offset);
                    func = fm.getFunctionAt(tryAddr);
                    if (func != null) {
                        println("  Found function @ -0x" + Integer.toHexString(offset) + ": " + func.getName());
                        decompileFunc(func, 150);
                        break;
                    }
                }
            }
        }
        
        // 3. LINK_CONTROL references
        println("\n[3] XVE LINK_CONTROL (0x8c000):");
        byte[] linkBytes = new byte[] {(byte)0x00, (byte)0xc0, (byte)0x08, (byte)0x00};
        Address linkAddr = memory.findBytes(currentProgram.getMinAddress(), linkBytes, null, true, monitor);
        if (linkAddr != null) {
            println("  LINK_CONTROL @ " + linkAddr);
            Function func = getFunctionContaining(linkAddr);
            if (func != null) {
                println("  Function: " + func.getName());
                decompileFunc(func, 80);
            }
        }
        
        println("\n============================================================");
        decompiler.dispose();
    }
    
    void decompileFunc(Function func, int maxLines) {
        try {
            DecompileResults results = decompiler.decompileFunction(func, 60, monitor);
            if (results.decompileCompleted()) {
                String code = results.getDecompiledFunction().getC();
                String[] lines = code.split("\n");
                println("  --- Decompiled (" + Math.min(lines.length, maxLines) + " lines) ---");
                for (int i = 0; i < lines.length && i < maxLines; i++) {
                    println("    " + lines[i]);
                }
                if (lines.length > maxLines) {
                    println("    ... (" + (lines.length - maxLines) + " more)");
                }
            } else {
                println("  [Decompilation failed]");
            }
        } catch (Exception e) {
            println("  [Error: " + e.getMessage() + "]");
        }
    }
}

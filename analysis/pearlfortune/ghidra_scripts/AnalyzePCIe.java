//Ghidra script to find PCIe Gen3 references
//@category Analysis
//@keybinding
//@menupath
//@toolbar

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;

public class AnalyzePCIe extends GhidraScript {
    
    @Override
    public void run() throws Exception {
        println("============================================================");
        println("PCIe Gen3 Analysis for cmpunlocker-rs");
        println("============================================================");
        
        Memory memory = currentProgram.getMemory();
        
        // Search strings
        String[] patterns = {
            "EnablePCIeGen3",
            "NVreg_EnablePCIeGen3",
            "RMPcieLinkSpeed",
            "Gen3",
            "kbifGetPciLinkMaxSpeedByPciGenInfo",
            "calculatePCIELinkRateMBps",
            "XVE_LINK_CONTROL",
            "pcie_cap",
            "nvidia-modprobe",
            "modprobe",
        };
        
        println("\n[1] STRING SEARCH:");
        for (String pattern : patterns) {
            if (monitor.isCancelled()) return;
            
            byte[] bytes = pattern.getBytes();
            Address addr = memory.findBytes(currentProgram.getMinAddress(), bytes, null, true, monitor);
            
            int count = 0;
            while (addr != null && count < 5) {
                println("  '" + pattern + "' @ " + addr);
                
                // Find xrefs
                Reference[] refs = getReferencesTo(addr);
                for (int i = 0; i < refs.length && i < 3; i++) {
                    Address from = refs[i].getFromAddress();
                    Function func = getFunctionContaining(from);
                    String fname = (func != null) ? func.getName() : "?";
                    println("    <- " + from + " in " + fname);
                }
                
                count++;
                addr = memory.findBytes(addr.add(1), bytes, null, true, monitor);
            }
        }
        
        // Search register addresses
        println("\n[2] REGISTER ADDRESSES (LE):");
        long[] regs = {
            0x00823810L,  // PCIE_FUSE
            0x0082057cL,  // OPT_GEN23
            0x00088088L,  // XVE LnkCap
            0x0008c000L,  // LINK_CONTROL
            0x0008c040L,  // LINK_SPEED
            0x0082381cL,  // SS0
            0x00823820L,  // SS1
        };
        String[] regNames = {"PCIE_FUSE", "OPT_GEN23", "XVE_LnkCap", "LINK_CONTROL", "LINK_SPEED", "SS0", "SS1"};
        
        for (int r = 0; r < regs.length; r++) {
            if (monitor.isCancelled()) return;
            
            long reg = regs[r];
            byte[] bytes = new byte[4];
            bytes[0] = (byte)(reg & 0xFF);
            bytes[1] = (byte)((reg >> 8) & 0xFF);
            bytes[2] = (byte)((reg >> 16) & 0xFF);
            bytes[3] = (byte)((reg >> 24) & 0xFF);
            
            Address addr = memory.findBytes(currentProgram.getMinAddress(), bytes, null, true, monitor);
            int count = 0;
            while (addr != null && count < 3) {
                println("  " + regNames[r] + " (0x" + Long.toHexString(reg) + ") @ " + addr);
                
                Reference[] refs = getReferencesTo(addr);
                for (int i = 0; i < refs.length && i < 2; i++) {
                    Address from = refs[i].getFromAddress();
                    Function func = getFunctionContaining(from);
                    String fname = (func != null) ? func.getName() : "?";
                    println("    <- " + from + " in " + fname);
                }
                
                count++;
                addr = memory.findBytes(addr.add(1), bytes, null, true, monitor);
            }
        }
        
        // List PCIe-related functions
        println("\n[3] PCIE/GEN3-RELATED FUNCTIONS:");
        FunctionManager fm = currentProgram.getFunctionManager();
        FunctionIterator funcs = fm.getFunctions(true);
        int funcCount = 0;
        while (funcs.hasNext() && funcCount < 50) {
            Function func = funcs.next();
            String name = func.getName().toLowerCase();
            if (name.contains("pcie") || name.contains("gen3") || name.contains("link") || 
                name.contains("xve") || name.contains("bifurcation") || name.contains("nvidia")) {
                println("  " + func.getName() + " @ " + func.getEntryPoint());
                funcCount++;
            }
        }
        
        // Decompile main or entry
        println("\n[4] LOOKING FOR MAIN/ENTRY:");
        Function main = null;
        for (Function f : fm.getFunctions(true)) {
            if (f.getName().equals("main") || f.getName().equals("_start") || 
                f.getName().contains("::main")) {
                main = f;
                println("  Found: " + f.getName() + " @ " + f.getEntryPoint());
            }
        }
        
        println("\n============================================================");
        println("Analysis complete. Use Ghidra GUI for detailed decompilation.");
        println("============================================================");
    }
}

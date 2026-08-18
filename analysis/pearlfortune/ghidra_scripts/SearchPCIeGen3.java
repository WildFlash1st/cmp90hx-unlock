// SearchPCIeGen3.java - Find PCIe Gen3 unlock logic in cmpunlocker-rs
//@category Analysis
//@keybinding
//@menupath
//@toolbar

import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import java.util.*;

public class SearchPCIeGen3 extends GhidraScript {
    
    @Override
    public void run() throws Exception {
        println("=== PCIe Gen3 Analysis for cmpunlocker-rs ===\n");
        
        // Search for PCIe-related strings
        String[] searchStrings = {
            "EnablePCIeGen3",
            "NVreg_EnablePCIeGen3", 
            "RMPcieLinkSpeed",
            "kbifGetPciLinkMaxSpeedByPciGenInfo",
            "823810",  // PCIE_FUSE
            "82057",   // OPT_GEN23
            "88088",   // XVE mirror
            "8c000"    // LINK_CONTROL
        };
        
        Memory memory = currentProgram.getMemory();
        
        for (String s : searchStrings) {
            println("Searching for: " + s);
            Address addr = memory.findBytes(currentProgram.getMinAddress(), 
                s.getBytes(), null, true, monitor);
            
            while (addr != null && !monitor.isCancelled()) {
                println("  Found at: " + addr);
                
                // Find xrefs to this address
                Reference[] refs = getReferencesTo(addr);
                for (Reference ref : refs) {
                    Address fromAddr = ref.getFromAddress();
                    Function func = getFunctionContaining(fromAddr);
                    if (func != null) {
                        println("    Referenced from function: " + func.getName() + 
                                " at " + fromAddr);
                    } else {
                        println("    Referenced from: " + fromAddr);
                    }
                }
                
                // Find next occurrence
                addr = memory.findBytes(addr.add(1), s.getBytes(), null, true, monitor);
            }
        }
        
        // Search for specific register addresses as 32-bit values
        println("\n=== Searching for register addresses ===");
        long[] registers = {
            0x00823810,  // PCIE_FUSE
            0x0082057c,  // OPT_GEN23
            0x00088088,  // XVE LnkCap
            0x0008c000   // LINK_CONTROL
        };
        
        for (long reg : registers) {
            byte[] bytes = new byte[4];
            bytes[0] = (byte)(reg & 0xFF);
            bytes[1] = (byte)((reg >> 8) & 0xFF);
            bytes[2] = (byte)((reg >> 16) & 0xFF);
            bytes[3] = (byte)((reg >> 24) & 0xFF);
            
            println("Searching for 0x" + Long.toHexString(reg) + " (LE)");
            Address addr = memory.findBytes(currentProgram.getMinAddress(), bytes, null, true, monitor);
            
            int count = 0;
            while (addr != null && !monitor.isCancelled() && count < 10) {
                println("  Found at: " + addr);
                count++;
                addr = memory.findBytes(addr.add(1), bytes, null, true, monitor);
            }
        }
        
        println("\n=== Analysis complete ===");
    }
}

#!/usr/bin/env python3
"""Extract and decompress Booter ucode from NVIDIA bindata C source."""
import re
import sys
import struct

def extract_data(c_file):
    """Parse g_bindata_*.c, extract all (label, size, compressed_size, data) tuples."""
    src = open(c_file).read()
    entries = []
    # Find all FUNCTION blocks
    for m in re.finditer(r'FUNCTION:\s*(\S+)\(("([^"]+)"|([^)]+))\)', src):
        pass  # just to verify pattern
    
    # Split by FUNCTION markers
    blocks = re.split(r'// FUNCTION:', src)[1:]
    for block in blocks:
        label_m = re.search(r'kgspBinArchiveBooterLoadUcode_GA102_(\w+)_data', block)
        size_m = re.search(r'// DATA SIZE \(bytes\):\s*(\d+)', block)
        csize_m = re.search(r'// COMPRESSED SIZE \(bytes\):\s*(\d+)', block)
        if not (label_m and size_m and csize_m):
            continue
        label = label_m.group(1)
        size = int(size_m.group(1))
        csize = int(csize_m.group(1))
        # Extract hex bytes
        data_start = block.find('{')
        data_end = block.find('};')
        if data_start < 0 or data_end < 0:
            continue
        hex_str = block[data_start+1:data_end]
        bytes_list = re.findall(r'0x([0-9a-fA-F]{2})', hex_str)
        data = bytes(int(b, 16) for b in bytes_list)
        if len(data) != csize:
            print(f"  WARNING {label}: declared {csize} bytes, extracted {len(data)}")
        entries.append((label, size, csize, data))
    return entries

def try_lz4(data, expected_size):
    """Try LZ4 block decompression (common NVIDIA bindata format)."""
    try:
        import lz4.block
        out = lz4.block.decompress(data, uncompressed_size=expected_size)
        return out
    except Exception as e:
        return None

def try_lz4_frameless(data, expected_size):
    """Try LZ4 without size header."""
    try:
        import lz4.block
        # Some formats prepend a 4-byte size
        if len(data) > 4:
            size_field = struct.unpack('<I', data[:4])[0]
            if size_field == expected_size:
                out = lz4.block.decompress(data[4:], uncompressed_size=expected_size)
                return out
    except Exception:
        pass
    return None

def try_gzip(data, expected_size):
    """Try gzip/zlib decompression (NVIDIA utilGzGetData = zlib inflate)."""
    import zlib
    # zlib with raw or gzip header
    for wbits in (15, 31, -15, 47):
        try:
            out = zlib.decompress(data, wbits)
            if len(out) >= expected_size:
                return out[:expected_size]
        except Exception:
            pass
    # try gzip module
    import gzip, io
    try:
        out = gzip.decompress(data)
        return out[:expected_size]
    except Exception:
        pass
    return None

if __name__ == '__main__':
    c_file = '/home/it/cmpunlocker-master/driver/.build/open-gpu-kernel-modules-610.43.03/src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c'
    entries = extract_data(c_file)
    print(f"Found {len(entries)} entries in {c_file}:")
    for label, size, csize, data in entries:
        print(f"  {label}: {csize} -> {size} bytes")
        out = try_gzip(data, size)
        if out:
            print(f"    -> GZIP OK! First bytes: {out[:32].hex()}")
            fn = f'/home/it/cmpunlocker-research/booter_{label.lower()}.bin'
            with open(fn, 'wb') as f:
                f.write(out)
            print(f"    -> Saved to {fn}")
        else:
            out = try_lz4(data, size)
            if out is None:
                out = try_lz4_frameless(data, size)
            if out:
                print(f"    -> LZ4 OK! Saved to booter_{label.lower()}.bin")
                with open(f'/home/it/cmpunlocker-research/booter_{label.lower()}.bin', 'wb') as f:
                    f.write(out)
            else:
                print(f"    -> FAILED both gzip and lz4")

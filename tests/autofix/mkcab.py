#!/usr/bin/env python3
"""mkcab.py OUT.cab NAME=FILE...: write an uncompressed Microsoft cabinet (test fixture writer)."""
import struct
import sys


def main(argv):
    out, members = argv[0], []
    for spec in argv[1:]:
        name, path = spec.split('=', 1)
        with open(path, 'rb') as f:
            members.append((name, f.read()))
    blob = b''.join(d for _, d in members)
    files = b''
    off = 0
    for name, data in members:
        files += struct.pack('<IIHHHH', len(data), off, 0, 0x5021, 0, 0x20) + name.encode() + b'\0'
        off += len(data)
    chunks = [blob[i:i + 32768] for i in range(0, len(blob), 32768)] or [b'']
    head_len, folder_len = 36, 8
    coff_files = head_len + folder_len
    data_start = coff_files + len(files)
    datas = b''.join(struct.pack('<IHH', 0, len(c), len(c)) + c for c in chunks)
    total = data_start + len(datas)
    header = b'MSCF' + struct.pack('<IIIIIBBHHHHH', 0, total, 0, coff_files, 0, 3, 1, 1, len(members), 0, 0x1234, 0)
    folder = struct.pack('<IHH', data_start, len(chunks), 0)
    with open(out, 'wb') as f:
        f.write(header + folder + files + datas)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

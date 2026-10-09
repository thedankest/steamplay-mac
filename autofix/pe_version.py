#!/usr/bin/env python3
"""pe_version.py: read the machine type and the version resource strings of a PE file.

    python3 -I pe_version.py FILE...                 all StringFileInfo entries, "key=value" lines
    python3 -I pe_version.py --field CompanyName FILE value of one entry (empty line if absent)
    python3 -I pe_version.py --machine FILE          i386 | x86_64 | arm64 | 0x<hex> | none

Standard library only, never executes anything. Reads at most 256 MiB of a file. Exit status
is 0 when every file parsed as PE, 1 otherwise. Used by autofix/detectors.sh (Creative OpenAL
detection) and autofix/installscript.py (vcredist year from the redist's version).
"""

import struct
import sys

MAX_READ = 256 * 1024 * 1024
RT_VERSION = 16
MACHINES = {0x14C: 'i386', 0x8664: 'x86_64', 0xAA64: 'arm64'}


class PE:
    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 0x40 or data[:2] != b'MZ':
            raise ValueError('not an MZ file')
        (lfanew,) = struct.unpack_from('<I', data, 0x3C)
        if lfanew + 24 > len(data) or data[lfanew:lfanew + 4] != b'PE\0\0':
            raise ValueError('no PE header')
        self.machine, nsec = struct.unpack_from('<HH', data, lfanew + 4)
        (optsize,) = struct.unpack_from('<H', data, lfanew + 20)
        opt = lfanew + 24
        (magic,) = struct.unpack_from('<H', data, opt)
        self.dirs = opt + (112 if magic == 0x20B else 96)
        self.sections = []
        sect = opt + optsize
        for i in range(min(nsec, 96)):
            s = sect + i * 40
            if s + 40 > len(data):
                break
            vsize, va, rsize, raw = struct.unpack_from('<IIII', data, s + 8)
            self.sections.append((va, max(vsize, rsize), raw))

    def rva(self, rva: int) -> int:
        for va, span, raw in self.sections:
            if va <= rva < va + span:
                off = raw + (rva - va)
                if off < len(self.data):
                    return off
        raise ValueError('rva outside sections')

    def directory(self, index: int):
        off = self.dirs + index * 8
        if off + 8 > len(self.data):
            return 0, 0
        return struct.unpack_from('<II', self.data, off)

    def version_resources(self):
        """Yield the raw bytes of every RT_VERSION resource."""
        rva, size = self.directory(2)
        if not rva or not size:
            return
        base = self.rva(rva)

        def entries(off):
            if off + 16 > len(self.data):
                return []
            named, ids = struct.unpack_from('<HH', self.data, off + 12)
            out = []
            for i in range(min(named + ids, 4096)):
                e = off + 16 + i * 8
                if e + 8 > len(self.data):
                    break
                out.append(struct.unpack_from('<II', self.data, e))
            return out

        for name, target in entries(base):
            if name & 0x80000000 or name != RT_VERSION or not target & 0x80000000:
                continue
            for _, t2 in entries(base + (target & 0x7FFFFFFF)):
                level3 = [(0, t2)] if not t2 & 0x80000000 else entries(base + (t2 & 0x7FFFFFFF))
                for _, t3 in level3:
                    if t3 & 0x80000000:
                        continue
                    leaf = base + t3
                    if leaf + 8 > len(self.data):
                        continue
                    drva, dsize = struct.unpack_from('<II', self.data, leaf)
                    try:
                        doff = self.rva(drva)
                    except ValueError:
                        continue
                    yield self.data[doff:doff + dsize]


def _align4(n: int) -> int:
    return (n + 3) & ~3


def _block(buf: bytes, off: int, end: int):
    """Parse one VS_VERSIONINFO-style block: returns (key, value_off, value_len_words, type, children_off, block_end)."""
    if off + 6 > end:
        return None
    length, vlen, vtype = struct.unpack_from('<HHH', buf, off)
    if length < 6:
        return None
    bend = min(off + length, end)
    k = off + 6
    key_chars = []
    while k + 2 <= bend:
        (ch,) = struct.unpack_from('<H', buf, k)
        k += 2
        if ch == 0:
            break
        key_chars.append(chr(ch))
    voff = _align4(k)
    return ''.join(key_chars), voff, vlen, vtype, bend


def string_table(res: bytes) -> dict:
    out = {}
    top = _block(res, 0, len(res))
    if not top or top[0] != 'VS_VERSION_INFO':
        return out
    _, voff, vlen, _, bend = top
    child = _align4(voff + vlen)
    while child < bend:
        blk = _block(res, child, bend)
        if not blk:
            break
        key, cvoff, _, _, cend = blk
        if key == 'StringFileInfo':
            table = _align4(cvoff)
            while table < cend:
                tb = _block(res, table, cend)
                if not tb:
                    break
                _, toff, _, _, tend = tb
                s = _align4(toff)
                while s < tend:
                    sb = _block(res, s, tend)
                    if not sb:
                        break
                    skey, soff, svlen, _, send = sb
                    raw = res[soff:send] if svlen else b''
                    val = raw.decode('utf-16-le', 'replace').split('\0', 1)[0]
                    out.setdefault(skey, val.strip())
                    s = _align4(send)
                table = _align4(tend)
        child = _align4(cend)
    return out


def read(path: str) -> bytes:
    with open(path, 'rb') as f:
        return f.read(MAX_READ)


def strings(path: str) -> dict:
    pe = PE(read(path))
    out = {}
    for res in pe.version_resources():
        for k, v in string_table(res).items():
            out.setdefault(k, v)
    return out


def machine(path: str) -> str:
    try:
        pe = PE(read(path))
    except (OSError, ValueError, struct.error):
        return 'none'
    return MACHINES.get(pe.machine, '0x%04x' % pe.machine)


def main(argv) -> int:
    field = None
    want_machine = False
    files = []
    it = iter(argv)
    for a in it:
        if a == '--field':
            field = next(it, None)
        elif a == '--machine':
            want_machine = True
        else:
            files.append(a)
    if not files:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    status = 0
    for path in files:
        if want_machine:
            m = machine(path)
            print(m)
            status |= m == 'none'
            continue
        try:
            table = strings(path)
        except (OSError, ValueError, struct.error) as e:
            print('pe_version: %s: %s' % (path, e), file=sys.stderr)
            table = {}
            status = 1
        if field is not None:
            print(table.get(field, ''))
        else:
            for k, v in table.items():
                print('%s=%s' % (k, v.replace('\n', ' ')))
    return status


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Make a signature profile for a Steam client build that no profile covers yet.

Read tools/make-signatures.md first. In short: notproton's anchors (strings, call sets,
instruction pairs) have been the same in every profile so far; only the recorded addresses and
byte patterns change per build. This tool carries the anchors of an existing profile forward to
the installed client, re-cuts the addresses and patterns from the client's own bytes, and keeps
the result only if notproton's anchorcheck then accepts it exactly as install.sh's gate does
(PLAN.md rule 5). An anchor that does not resolve, a pattern that is not unique, or any
anchorcheck complaint stops it, and nothing is written.

A written profile is marked "generated.reviewed": false. install.sh's gate ignores it until a
person has compared the code at the new addresses with the old build and run
  tools/make-signatures.py --mark-reviewed signatures/macos.arm64/<build>.json --by "<name>"
because the anchor is the only independent evidence the tool has: the recorded address and the
new pattern are both cut where the anchor landed, so anchorcheck agreeing with them proves
nothing more. Rows where the old build's own pattern also lands on the anchor are listed as
confirmed; the others need the closer look.

Read-only on Steam: it dlopens the client through anchorcheck and reads the dylibs. It does not
touch Steam.app or the support directory.

Usage: tools/make-signatures.py [--from PROFILE] [--build N] [--out DIR] [--dry-run]
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPSTREAM_SIGS = os.path.join(REPO, "notproton", "signatures", "macos.arm64")
LOCAL_SIGS = os.path.join(REPO, "signatures", "macos.arm64")
DEFAULT_MODULE = "steamclient.dylib"
MAX_PATTERN = 160  # bytes; notproton's own patterns are 32 to 72

ROW = re.compile(r"^  (\S+)\s+(\S+)\s+anchor=0x([0-9a-f]+)\s+recorded=0x([0-9a-f]+)\s+aob=0x([0-9a-f]+)\s+(.*?)\s*$")
HEADER = re.compile(r"^(\S.*\.json)  build (\d+)(  \[live client\])?\s*$")
SUMMARY = re.compile(r"^\s+(\d+) anchors resolved, (\d+) unresolved")


def die(msg, code=1):
    print("make-signatures: " + msg, file=sys.stderr)
    sys.exit(code)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- Mach-O ----------------------------------------------------------------------------------
class Image:
    """The arm64 slice of a (possibly universal) Mach-O, addressed by unslid vmaddr."""

    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        base = 0
        magic = struct.unpack(">I", data[:4])[0]
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            n = struct.unpack(">I", data[4:8])[0]
            wide = magic == 0xCAFEBABF
            off, step = 8, (32 if wide else 20)
            for _ in range(n):
                if wide:
                    cpu, _sub, foff, _size = struct.unpack(">iiQQ", data[off:off + 24])
                else:
                    cpu, _sub, foff, _size = struct.unpack(">iiII", data[off:off + 16])
                if cpu == 0x0100000C:
                    base = foff
                    break
                off += step
            else:
                raise ValueError(path + " has no arm64 slice")
        if struct.unpack("<I", data[base:base + 4])[0] != 0xFEEDFACF:
            raise ValueError(path + ": arm64 slice is not a 64-bit Mach-O")
        ncmds = struct.unpack("<I", data[base + 16:base + 20])[0]
        self.data, self.segs = data, []
        off = base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack("<II", data[off:off + 8])
            if cmd == 0x19:  # LC_SEGMENT_64
                name = data[off + 8:off + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[off + 24:off + 56])
                self.segs.append((name, vmaddr, vmsize, base + fileoff, filesize))
            off += size

    def text(self):
        for name, vmaddr, _vs, foff, fsize in self.segs:
            if name == "__TEXT":
                return vmaddr, self.data[foff:foff + fsize]
        raise ValueError("no __TEXT")

    def read(self, addr, n):
        for _name, vmaddr, _vs, foff, fsize in self.segs:
            if vmaddr <= addr and addr + n <= vmaddr + fsize:
                return self.data[foff + addr - vmaddr:foff + addr - vmaddr + n]
        raise ValueError("0x%x+%d is outside the file's segments" % (addr, n))


# --- patterns --------------------------------------------------------------------------------
def build_mask(code):
    """Per-byte keep flags for arm64 code: wildcard what moves between client builds.

    Masked: BL and B (calls and tail calls into other functions), ADRP, ADR, LDR (literal), and
    the ADD/LDR/STR immediate that completes an ADRP page reference. Branches inside the
    function (B.cond, CBZ/CBNZ, TBZ/TBNZ) and everything else stay fixed, so a pattern only
    matches the same code."""
    keep = [True] * len(code)
    pages = set()
    for i in range(0, len(code) - 3, 4):
        w = struct.unpack("<I", code[i:i + 4])[0]
        wild = False
        if (w & 0x7C000000) == 0x14000000:      # B, BL
            wild = True
        elif (w & 0x9F000000) == 0x90000000:    # ADRP
            wild = True
            pages.add(w & 0x1F)
        elif (w & 0x9F000000) == 0x10000000:    # ADR
            wild = True
        elif (w & 0x3B000000) == 0x18000000:    # LDR (literal)
            wild = True
        elif (w & 0xFF800000) == 0x91000000 and ((w >> 5) & 0x1F) in pages:   # ADD Xd, Xpage, #off
            wild = True
        elif (w & 0x3B000000) == 0x39000000 and ((w >> 5) & 0x1F) in pages:   # LDR/STR [Xpage, #off]
            wild = True
        if wild:
            for k in range(4):
                keep[i + k] = False
    return keep


def fmt_pattern(code, keep):
    return " ".join("%02X" % b if k else "??" for b, k in zip(code, keep))


def compile_pattern(text):
    toks = text.split()
    rx = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in toks)
    return re.compile(rx, re.DOTALL), len(toks)


def hits(text_bytes, pattern, limit=2):
    rx, _n = compile_pattern(pattern)
    out, pos = [], 0
    while len(out) < limit:
        m = rx.search(text_bytes, pos)
        if not m:
            break
        out.append(m.start())
        pos = m.start() + 1
    return out


# --- anchorcheck -----------------------------------------------------------------------------
def anchorcheck(ac, home, profiles):
    """Run anchorcheck over the given profiles (all of them staged in one temp dir, the way
    install.sh stages them) and parse it. Returns (exit code, output, blocks)."""
    root = tempfile.mkdtemp(prefix="np-makesig-")
    try:
        sd = os.path.join(root, "signatures", "macos.arm64")
        os.makedirs(sd)
        for p in profiles:
            shutil.copy(p, sd)
        env = dict(os.environ, HOME=home)
        cmd = [ac] if len(profiles) > 1 else [ac, "signatures/macos.arm64/" + os.path.basename(profiles[0])]
        r = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    out = r.stdout + r.stderr
    blocks, cur = [], None
    for line in out.splitlines():
        m = HEADER.match(line)
        if m:
            cur = {"path": m.group(1), "build": int(m.group(2)), "live": bool(m.group(3)), "rows": []}
            blocks.append(cur)
            continue
        if cur is None:
            continue
        m = ROW.match(line)
        if m:
            cur["rows"].append({"name": m.group(1), "kind": m.group(2), "anchor": int(m.group(3), 16),
                                "recorded": int(m.group(4), 16), "aob": int(m.group(5), 16),
                                "verdict": m.group(6)})
            continue
        m = SUMMARY.match(line)
        if m and "resolved" not in cur:
            cur["resolved"], cur["unresolved"] = int(m.group(1)), int(m.group(2))
    return r.returncode, out, blocks


def known_profiles(dirs):
    seen = {}
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if re.fullmatch(r"\d+\.json", f):
                p = os.path.join(d, f)
                if f in seen and sha256(seen[f]) != sha256(p):
                    die("%s exists twice (%s, %s) with different content" % (f, seen[f], p))
                seen[f] = p
    return seen


def manifest_version(inner):
    p = os.path.join(inner, "package", "steam_client_osx.manifest")
    try:
        with open(p) as f:
            m = re.search(r'"version"\s+"(\d+)"', f.read())
    except OSError:
        return None
    return int(m.group(1)) if m else None


def main():
    home = os.environ.get("NP_HOME", os.path.expanduser("~"))
    support = os.path.join(home, "Library", "Application Support", "notproton")
    inner = os.path.join(home, "Library", "Application Support", "Steam", "Steam.AppBundle",
                         "Steam", "Contents", "MacOS")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", help="profile whose anchors are carried forward (default: the highest-numbered one)")
    ap.add_argument("--build", type=int, help="build number for the new profile (default: the client's steam_client_osx.manifest version)")
    ap.add_argument("--out", default=LOCAL_SIGS, help="where the new profile goes (default: %(default)s)")
    ap.add_argument("--anchorcheck", help="anchorcheck binary (default: the installed one, else notproton/out/anchorcheck)")
    ap.add_argument("--known", action="append", metavar="DIR",
                    help="profile directories that count as existing (default: notproton's and this repo's; repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="check and print, write nothing")
    ap.add_argument("--mark-reviewed", metavar="PROFILE", help="record that a person checked a generated profile")
    ap.add_argument("--by", help="with --mark-reviewed: who checked it")
    a = ap.parse_args()

    if a.mark_reviewed:
        if not a.by:
            die("--mark-reviewed needs --by \"<name>\"")
        with open(a.mark_reviewed) as f:
            p = json.load(f)
        if "generated" not in p:
            die("%s was not made by this tool" % a.mark_reviewed)
        p["generated"].update(reviewed=True, reviewed_by=a.by,
                              reviewed_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        with open(a.mark_reviewed + ".tmp", "w") as f:
            json.dump(p, f, indent=2)
            f.write("\n")
        os.replace(a.mark_reviewed + ".tmp", a.mark_reviewed)
        print("marked reviewed by %s: %s" % (a.by, a.mark_reviewed))
        return 0

    ac = a.anchorcheck
    if not ac:
        for c in (os.path.join(support, "tools", "anchorcheck"), os.path.join(REPO, "notproton", "out", "anchorcheck")):
            if os.access(c, os.X_OK):
                ac = c
                break
    if not ac or not os.access(ac, os.X_OK):
        die("no anchorcheck (build it with: make -C notproton anchorcheck)")

    dirs = a.known or [UPSTREAM_SIGS, LOCAL_SIGS]
    profiles = known_profiles(dirs)
    if not profiles:
        die("no profiles in " + ", ".join(dirs))
    src = a.src or profiles[max(profiles, key=lambda f: int(f[:-5]))]
    with open(src) as f:
        prof = json.load(f)
    sigs = prof["signatures"]

    # 1. Is this client already covered?
    rc, out, blocks = anchorcheck(ac, home, list(profiles.values()))
    if not blocks:
        die("anchorcheck printed nothing usable (exit %d):\n%s" % (rc, out), 3)
    live = [b for b in blocks if b["live"]]
    if live:
        die("this client is already covered by %s (build %d); nothing to make" % (os.path.basename(live[0]["path"]), live[0]["build"]), 0)

    build = a.build or manifest_version(inner)
    if not build:
        die("cannot read the client version from %s/package/steam_client_osx.manifest; pass --build" % inner)
    name = "%d.json" % build
    if name in profiles:
        die("%s already exists but does not describe this client; pass a different --build" % name)

    # 2. The source profile's anchors on this client.
    rc, out, blocks = anchorcheck(ac, home, [src])
    if len(blocks) != 1:
        die("anchorcheck on %s gave %d blocks (exit %d):\n%s" % (src, len(blocks), rc, out), 3)
    rows = {r["name"]: r for r in blocks[0]["rows"]}
    problems, confirmed = [], set()
    for s in sigs:
        r = rows.get(s["name"])
        if not r:
            problems.append("%s: no row in anchorcheck's output" % s["name"])
        elif not r["anchor"]:
            problems.append("%s: anchor does not resolve (%s)" % (s["name"], r["verdict"]))
        elif r["verdict"] != "resolved":
            problems.append("%s: %s" % (s["name"], r["verdict"]))
        elif r["aob"] and r["aob"] == r["anchor"]:
            confirmed.add(s["name"])
    if problems:
        die("the anchors of %s do not carry over to this client, so a new profile needs real work "
            "(see tools/make-signatures.md, 'When this tool stops'):\n  " % os.path.basename(src)
            + "\n  ".join(problems))

    # 3. Re-cut addresses and patterns from the client's own bytes.
    images, new, table = {}, [], []
    for s in sigs:
        mod = s.get("module") or DEFAULT_MODULE
        if mod not in images:
            images[mod] = Image(os.path.join(inner, mod))
        im = images[mod]
        site = rows[s["name"]]["anchor"]
        n = len(s["aob_hex"].split())
        hit = site + int(s.get("match_offset") or 0)
        if hit % 4:
            die("%s: pattern start 0x%x is not instruction-aligned" % (s["name"], hit))
        tbase, tbytes = im.text()
        # Start at the source pattern's length; lengthen it until it matches only its own site.
        while True:
            code = im.read(hit, n)
            pat = fmt_pattern(code, build_mask(code))
            if not compile_pattern(pat)[0].match(tbytes, hit - tbase):
                die("%s: the re-cut pattern does not match its own site in %s" % (s["name"], mod))
            found = hits(tbytes, pat)
            if found == [hit - tbase]:
                break
            n += 8
            if n > MAX_PATTERN:
                die("%s: even %d bytes match %d places in %s's __TEXT; this needs a pattern made by hand "
                    "(see tools/make-signatures.md)" % (s["name"], MAX_PATTERN, len(found), mod))
        e = dict(s)
        e["aob_hex"] = pat
        e["func_addr_this_build"] = "0x%x" % site
        new.append(e)
        old = int(s["func_addr_this_build"], 16) if s.get("func_addr_this_build") else 0
        table.append((s["name"], old, site, n, pat.count("??")))

    cand = dict(prof)
    cand["steam_build"] = build
    cand["steam_build_date"] = ""
    cand["signatures"] = new
    cand["generated"] = {
        "tool": "tools/make-signatures.py",
        "from_profile": os.path.basename(src),
        "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "client_sha256": {m: sha256(os.path.join(inner, m)) for m in sorted(images)},
        "anchorcheck_sha256": sha256(ac),
        "confirmed_by_old_pattern": sorted(confirmed),
        "anchor_only": sorted(x["name"] for x in sigs if x["name"] not in confirmed),
        "reviewed": False,
    }

    # 4. The same checks as install.sh's gate (scripts/lib/gate.sh), on the candidate.
    tmp = tempfile.mkdtemp(prefix="np-makesig-cand-")
    try:
        cpath = os.path.join(tmp, name)
        with open(cpath, "w") as f:
            json.dump(cand, f, indent=2)
            f.write("\n")
        rc_all, out_all, blocks_all = anchorcheck(ac, home, list(profiles.values()) + [cpath])
        live = [b for b in blocks_all if b["live"]]
        if len(live) != 1 or os.path.basename(live[0]["path"]) != name or live[0]["build"] != build:
            die("with every profile staged, anchorcheck did not mark %s alone as the live client:\n%s" % (name, out_all))
        rc1, out1, blocks1 = anchorcheck(ac, home, [cpath])
        ok = (rc1 == 0 and len(blocks1) == 1 and blocks1[0]["live"]
              and blocks1[0].get("resolved") == len(new) and blocks1[0].get("unresolved") == 0
              and all(r["verdict"] == "OK" for r in blocks1[0]["rows"]))
        if not ok:
            die("anchorcheck rejects the candidate (exit %d):\n%s" % (rc1, out1))

        print("client build %d (from %s): %d/%d anchors resolve uniquely; %d of them confirmed by the old "
              "build's own pattern, %d anchor only" % (build, os.path.basename(src), len(new), len(new),
                                                     len(confirmed), len(new) - len(confirmed)))
        for nm, old, site, n, wild in table:
            print("  %-56s 0x%-8x -> 0x%-8x (%+7d)  pattern %3d bytes, %2d wildcards  %s"
                  % (nm, old, site, site - old, n, wild, "confirmed" if nm in confirmed else "ANCHOR ONLY"))
        if a.dry_run:
            print("dry run: nothing written")
            return 0
        os.makedirs(a.out, exist_ok=True)
        dst = os.path.join(a.out, name)
        if os.path.exists(dst):
            die("%s appeared while this ran; not overwriting it" % dst)
        shutil.copy(cpath, dst + ".tmp")
        os.replace(dst + ".tmp", dst)
        print("wrote " + dst + " (not reviewed: install.sh ignores it until --mark-reviewed)")
        print("next: compare the ANCHOR ONLY rows with the old build in a disassembler, then\n"
              "  tools/make-signatures.py --mark-reviewed %s --by \"<name>\"\n"
              "  scripts/install.sh reapply" % dst)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Signature profiles for a new Steam client

`notproton.dylib` finds the Steam functions it hooks by **anchors**: a unique string the function
references, the set of functions it calls, or an instruction pair inside it. A **profile**
(`<build>.json`) lists those anchors together with, for one client build, the address each one
lands on and a byte pattern of the code there. `install.sh` installs and re-applies Steam Play
only when one profile describes the installed client exactly (PLAN.md rule 5, `scripts/lib/gate.sh`):
anchorcheck must mark it as the live client, resolve every anchor, and find the recorded addresses
and patterns where the anchors land.

When Steam updates its client and no profile fits, `install.sh reapply` (and the update watcher)
switches Steam Play off, so no hooks load, and tells you. Steam.app is not changed. Two ways out:

1. **Upstream has a profile.** NotProton publishes profiles for new builds in
   `notproton/signatures/macos.arm64/`. Bump the submodule (UPSTREAM.md), re-apply the patches
   (`scripts/apply-notproton-patches.sh`), run `scripts/install.sh reapply`.
2. **Make one here** with `tools/make-signatures.py`, below.

## `tools/make-signatures.py`

```
python3 -I tools/make-signatures.py --dry-run     # check and print only
python3 -I tools/make-signatures.py               # write signatures/macos.arm64/<build>.json
# compare the ANCHOR ONLY rows with the old build in a disassembler, then:
python3 -I tools/make-signatures.py --mark-reviewed signatures/macos.arm64/<build>.json --by "<name>"
scripts/install.sh reapply                        # the gate runs again, then re-applies
```

A generated profile is written with `"generated": {"reviewed": false}`, and `install.sh`'s gate
skips it (and says so) until `--mark-reviewed` records who checked it. So neither the watcher nor
an interactive reapply turns hooks back on from a profile no person has looked at.

What it does:

1. Runs anchorcheck over every known profile (notproton's and `signatures/macos.arm64/`). If one is
   already the live client, it stops: nothing to do.
2. Runs anchorcheck on the source profile (default: the highest-numbered). Every anchor must
   resolve on the installed client with the verdict `resolved`. A failed anchor, or an old pattern
   that hits a different place than its anchor, stops it. A row where the old build's own pattern
   also lands exactly on the anchor is **confirmed**; the rest are **anchor only** and are listed
   for review.
3. Re-cuts each signature from the client's own bytes (the arm64 slice of `steamclient.dylib` or
   `steamui.dylib`): the address is where the anchor landed, and the pattern is the code there with
   everything that moves between builds masked (`BL`/`B`, `ADRP`/`ADR`, literal loads and the
   `ADD`/`LDR`/`STR` that complete an `ADRP` page reference). The pattern starts at the source
   pattern's length and grows by 8 bytes until it matches only its own site in `__TEXT` (at most
   160 bytes).
4. Checks the candidate the way the gate does: with every profile staged, anchorcheck marks it
   alone as the live client; on its own, anchorcheck exits 0 with every row `OK` (anchor, recorded
   address and pattern agree), N/N resolved, and the byte-pattern fallback (anchors forced to miss)
   lands on the same addresses.
5. Only then writes `signatures/macos.arm64/<build>.json`. The file also records which profile it
   came from, when, the client's SHA-256 and anchorcheck's SHA-256 (`generated`).

`<build>` defaults to the `version` in the client's `package/steam_client_osx.manifest`. That is not
always the number upstream uses: upstream's 1788400362 profile describes the client the manifest
calls 1788652215. The number only names the file and must be unique; pass `--build` to choose it.

It is read-only on Steam: anchorcheck dlopens the client in its own process, and the tool reads the
dylibs from disk. It never touches Steam.app, the support directory or Steam's settings.

## What the checks prove, and what they don't

The anchor is the only independent evidence. The new address and the new pattern are both cut
where the anchor landed, so anchorcheck agreeing with them (step 4) only proves the profile is
well-formed and unique, not that the anchor found the right function. That is why a person
reviews the anchor-only rows before the gate will use the profile (rule 5: no guessed offsets).
An anchor can resolve uniquely to the wrong function, for example when Valve moves a log string
into a helper. The review is: open the old and new client in a disassembler, and check that each
anchor-only address is the same function (same calls, same strings, same shape).

For comparison, the dylib itself resolves every hook from its anchors at runtime, whatever build a
profile names; the gate is the stricter check.

Checked on 2026-10-10 against the installed client (manifest 1788652215): with upstream's
1788400362 profile hidden, the tool built a profile from the 1790904859 anchors (and again from
1789086785); 10 rows were confirmed by the old pattern, 7 were anchor only. All 17 addresses
equal the ones in upstream's hand-made 1788400362 profile, which is the review done against a
primary source, and the 441 fixed bytes both patterns cover agree with no conflict.
`scripts/lib/gate.sh` passes it (17/17, anchorcheck exit 0) once marked reviewed. Negative
check: a profile with one broken anchor stops at step 2 and writes nothing.

## When this tool stops

- **An anchor does not resolve** (Valve renamed a log string, inlined a function, changed its
  calls). A new anchor needs someone to read the new client's code. That is reverse-engineering
  work and out of scope for the automatic path; until it is done, Steam Play stays off for that
  client and Steam keeps working normally. Options: wait for a NotProton release, or do it by hand
  in a disassembler and add the result to `signatures/macos.arm64/`.
- **A pattern is not unique within 160 bytes.** Write that one pattern by hand (a longer or
  differently placed run of fixed bytes, with `match_offset` if it does not start at the site) and
  check it with anchorcheck.
- **Two profiles are marked live.** Upstream added a profile for the same client under another
  number. Delete the local one in `signatures/macos.arm64/`.

anchorcheck also checks class vtable pointers for the builds it knows (`notproton/dylib/tests/anchorcheck.c`,
`expected_vptr`). It has none for a new build and prints "no vptr expectations", which is not a
failure. Adding rows for a new build is optional and needs the addresses read off the disassembly.

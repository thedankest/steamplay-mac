# Upstream inputs

Runner A's pins (CrossOver 26.3.0, MoltenVK, FFmpeg, Mono, Gecko, DXMT, GPTK, Valve packages)
are still listed in the scripts that fetch them and in ARCHITECTURE.md. They move here in
Phase 5. This file covers Runner B so far.

## Runner B: ARM64 Wine 11.18 + FEX, no Rosetta

The machine-readable pins are in `ci/runner-b-inputs.json`. `scripts/build-wine-arm64.sh` and
`scripts/assemble-runner-b.sh` read them, and refuse to run on a `TODO-PIN` or a mismatch.
Run `scripts/build-wine-arm64.sh --print-plan` to see every pin and its status without a network.

| Input | Version / commit | Where it comes from | Licence | In the repo? |
|---|---|---|---|---|
| Wine | 11.18 (tag `wine-11.18`, commit 7b3fff76f101) | dl.winehq.org tarball | LGPL-2.1-or-later | no, fetched |
| llvm-mingw | 20260922, ucrt, macOS universal | github.com/mstorsjo/llvm-mingw release | Apache-2.0 with LLVM exception (build tool only) | no, fetched |
| FEX DLLs | Hangover 11.16 `hangover_11.16_dlls.tar` (FEX 2608) | github.com/AndreRH/hangover release | MIT | no, fetched |
| Highball patches 0003, 0018, 0019 | highball-engine `ac5cc83` (`patches-arm64/`) | github.com/gauthierpiarrette/highball-engine | LGPL-2.1-or-later | yes: `patches/highball/0003-*` (shared with Runner A), `patches/highball-arm64/` |
| `fexunixlib_darwin.cpp` | highball-engine `ac5cc83` (`fex/`) | same | MIT (derived from FEX's `Source/Windows/UnixLib`) | yes: `runner-b/fex/`, with FEX's licence text in `runner-b/fex/LICENSE.FEX` |
| Our patch 0020 (loader in `wine.app`) | ours | `patches/runner-b/` | LGPL-2.1-or-later, like the Wine files it changes | yes |
| Our kr trace for the FEX helper | ours | `runner-b/fex/0001-fexunixlib-trace-kr.patch` | MIT, like the file it changes | yes |
| MoltenVK | 1.4.2 (universal) | Runner A's pin | Apache-2.0 | no, fetched |
| gmp, gnutls, freetype | CrossOver 26.3.0 source drop | Runner A's pin | LGPL / GPL / FTL as in the drop | no, fetched |
| nettle, SDL2, FFmpeg | 3.10.2, 2.32.10, 7.1.5 | Runner A's pins | LGPL / zlib / LGPL | no, fetched |
| wine-mono | 11.3.0 MSIs (x86, arm64) | dl.winehq.org; version and hashes from wine-11.18 `dlls/appwiz.cpl/addons.c` | MIT and others (Mono) | no, fetched |
| wine-gecko | 2.47.4 MSIs (x86, x86_64) | Runner A's pins; equal to wine-11.18 `addons.c` | MPL-2.0 | no, fetched |

### Licence check (2026-10-09)

- **Highball patches:** highball-engine's `LICENSE` is LGPL-2.1, and its `NOTICE.md` lists the
  patch series as LGPL-2.1-or-later. Redistribution is allowed under the LGPL, so the patches are
  copied into this repo unchanged. Their headers name Highball as the source. This GPL-3.0 repo
  can carry LGPL-2.1-or-later files.
- **`fexunixlib_darwin.cpp`:** `NOTICE.md` lists it as MIT, after FEX's UnixLib. The file has no
  copyright line of its own, so FEX's MIT licence text (copyright 2019 Ryan Houdek) is next to it
  in `runner-b/fex/LICENSE.FEX`, as the MIT licence requires.
- **Hangover DLLs:** MIT (FEX). They are downloaded at build time and never committed.
  `assemble-runner-b.sh` puts FEX's licence text into `share/doc/fex/LICENSE` in the runner.
- **No Apple or Valve binaries** are committed or bundled (rule 3). Runner B never includes
  D3DMetal: `assemble-runner-b.sh` and `runner-b.yml` both fail on any D3DMetal, GPTK or Valve
  file, and on any provisioning profile in the CI tarball.

### How to bump

1. Change the version in `ci/runner-b-inputs.json`.
2. Take the sha256 from a primary source, such as the GitHub release asset digest
   (`gh api repos/<o>/<r>/releases/tags/<t> --jq '.assets[]|.name+" "+.digest'`) or the checksum
   upstream publishes. Never use a hash computed from a download you have not otherwise checked.
3. For a Wine bump, diff the tarball once against the git tag. Re-run the patch stage on a fresh
   tree: `rm -rf build/wine-arm64/src` and then `scripts/build-wine-arm64.sh fetch patch`.
   Rebase 0020 if needed and update its pin.
4. Update the wine-mono and wine-gecko versions and hashes from the new tree's
   `dlls/appwiz.cpl/addons.c`.
5. Drop Highball 0018/0019 and our 0020 once Brendan Shanks' arm64 macOS merge requests land
   upstream with equivalents.

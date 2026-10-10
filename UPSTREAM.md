# Upstream inputs

Every upstream input, where its pin lives and how to bump it: Runner B first, then Runner A and
the installer's support files. New Steam client builds are not a pin; see
`tools/make-signatures.md`.

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

## Runner A: CrossOver 26.3 sources (Wine 11.0), x86_64 under Rosetta 2

The pin lives in the script that fetches each input; that script checks the hash before it uses the
file. To bump: change the URL and the sha256 together, taking the hash from a primary source (a
release asset digest, or the checksum upstream publishes), never from an unchecked download.

| Input | Version / commit | Source | sha256 | Pin at |
|---|---|---|---|---|
| CrossOver sources (Wine 11.0, plus the bundled gmp, gnutls, freetype) | 26.3.0 | media.codeweavers.com `crossover-sources-26.3.0.tar.gz` | `ac99c8ca…6872` | `scripts/prepare-wine-src.sh:11` |
| nettle | 3.10.2 | ftpmirror.gnu.org | `fe9ff51c…19b5` | `scripts/build-deps.sh:84` |
| SDL2 | 2.32.10 | github.com/libsdl-org/SDL release | `5f5993c5…5165` | `scripts/build-deps.sh:120` |
| MoltenVK | 1.4.2, prebuilt `MoltenVK-macos.tar` | github.com/KhronosGroup/MoltenVK release | `f95765a6…024e` | `scripts/build-deps.sh:132` |
| FFmpeg | 7.1.5 | ffmpeg.org | `de668509…558f` | `scripts/build-deps.sh:146` |
| wine-mono | 10.4.1 x86 | dl.winehq.org | `a16606ef…99bb` | `scripts/assemble-runner.sh:62` |
| wine-gecko | 2.47.4 x86 / x86_64 | dl.winehq.org | `26cecc47…93d6` / `e590b7d9…066f` | `scripts/assemble-runner.sh:65` |
| DXMT | v0.80, prebuilt `builtin` tarball | github.com/3Shain/dxmt release | `8f260e36…529d` | `scripts/assemble-runner.sh:71` |
| D3DMetal (default) | GPTK 3.0-3, Gcenx repack | github.com/Gcenx/game-porting-toolkit release | `d3776839…392e` | `scripts/install-d3dmetal.sh:47` |
| D3DMetal (`--gptk-dmg`) | GPTK 4.0 beta 2, Apple's DMG (user downloads it) | developer.apple.com | outer `03893ac4…ee5b`, eval `6248a0ed…ecc1`, licence `5abb2d05…18c8` | `scripts/install-d3dmetal.sh:52` (`DMG_KNOWN`, `APPLE_LICENSES`) |
| Dobby (dylib hooks) | commit `5dfc8546954c` | GitHub archive tarball | `01a41723…3748` | `scripts/install.sh` (`support_dobby`) and `scripts/build-all.sh:64`: change both |
| Wine for the steam.exe shim | wine-11.15 | dl.winehq.org | `5046f36d…c272` | `scripts/build-steam-shim.sh:16` |
| Proton lsteamclient sources | Proton commit `164e0ccd2ea2` | codeload.github.com | content digest `b286df1d…57bf` (of the extracted tree) | `scripts/fetch-steam-sources.sh:17` |
| openvr headers, Valve wine `heap.h` | `f51d87ecf8f7`, `015230dc0f78` | raw.githubusercontent.com | per file | `scripts/fetch-steam-sources.sh:19` |
| Valve bridge packages | as listed | Valve's client CDN | per package and per file | `notproton/app/Sources/NotProtonApp/Resources/valve-packages.manifest` (pinned by the notproton commit) |
| NotProton | `ff101e690d39` (1.0.3-6), branch `selfbuilt-wine` | github.com/Drustburn/NotProton | git commit | `.gitmodules`, submodule gitlink |
| Runner A release tarball | not filled yet | GitHub release of this repo | empty | `ci/runner-a.lock` (`install.sh all --from release` refuses until it is filled) |

Not pinned by hash: the Homebrew build tools (mingw-w64, bison, flex, meson, ninja, cmake, llvm,
nasm, zstd, …; versions recorded in `SETUP.md`), and the CI runner image label `macos-15`. GitHub
Actions in `runner-a.yml` are pinned by commit.

### How to bump

- **CrossOver sources.** Change `CX_URL`/`CX_SHA` in `scripts/prepare-wine-src.sh`. nettle is the
  release the CrossOver drop was cut from (`build-deps.sh:83`), so bump it with the drop. Re-run
  `scripts/build-wine.sh` on a fresh tree, re-apply `patches/series`, and re-run the Phase 1 gate
  games (Mewgenics, Alien Breed 3, Librarian). Runner B shares some of these pins:
  `build-wine-arm64.sh` (`check_shared_pins`) refuses to run until `ci/runner-b-inputs.json` agrees.
- **DXMT, MoltenVK, FFmpeg, SDL2, wine-mono/gecko.** Change URL and hash in the script named above,
  rebuild with `scripts/build-all.sh`, and run d3dprobe (FL 11_0 for DXMT) plus the gate games.
- **GPTK / D3DMetal.** A new Apple DMG: add its outer and eval image hashes to `DMG_KNOWN`, and its
  licence hash to `APPLE_LICENSES` only after reading the licence. The user accepts the licence at
  install time; nothing from GPTK is committed (rule 3).
- **NotProton.** `git -C notproton fetch` and check out the new commit, then
  `scripts/apply-notproton-patches.sh --check`; rebase our patches in `patches/notproton/` if it
  fails. New upstream signature profiles come with it (`notproton/signatures/macos.arm64/`). If one
  covers a client that `signatures/macos.arm64/` (ours, from `tools/make-signatures.py`) also
  covers, delete ours, or the gate sees two live profiles and stops. Run `tests/installer`, then
  `install.sh all` (it rebuilds the dylib and re-runs the gate).
- **Dobby.** Change commit and hash in both `scripts/install.sh` and `scripts/build-all.sh`.
- **A new Steam client.** Not a pin: see `tools/make-signatures.md`.

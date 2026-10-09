# CI notes: Runner A workflow

## Runner image decision: arm64 `macos-15` (option A)
- `scripts/build-all.sh` exits on non-arm64, and build-deps/build-wine/build-steam-shim hardcode
  `/opt/homebrew`, build native arm64 tools (`--enable-archs=aarch64` tools tree, Homebrew
  llvm/lld) and cross-compile x86_64 with `clang -arch x86_64` (`--build=aarch64-apple-darwin`).
  An Intel runner would need edits to every script and would not match the local build, which
  is what the Phase 2 gate compares against.
- The "Unix side must be x86_64" requirement is met by the cross-compile; Rosetta is only
  needed to execute the result (`wine --version` in build-wine/assemble, configure probes).
- Rosetta: the workflow runs `arch -x86_64 /usr/bin/true` and, if that fails, `softwareupdate
  --install-rosetta --agree-to-license`. UNVERIFIED that this works on the hosted arm64 VM.
  Fallback if it does not: option B (macos-15-intel plus the script changes below, not written).
- Hosted arm64 `macos-15` has 3 cores / 7 GB; expect a long build. `macos-15-xlarge` is a drop-in.
- Checkout path (`/Users/runner/work/<repo>/<repo>`) has no spaces; the workflow asserts it.

## Workflow shape
Does not call build-all.sh. It runs prepare-wine-src, build-deps, build-wine, build-steam-shim,
assemble-runner, in build-all's (locally modified) order. Skipped on purpose:
- fetch-valve-bridge.sh (downloads Valve DLLs into build/bridge; assemble never copies them,
  only `build/bridge/steam.exe`, the LGPL shim built from stock Wine 11.15).
- NotProton fork build (Dobby, dylib, helpers): not part of the runner tree.
The `notproton` submodule is still checked out (build-steam-shim uses notproton/bridge and
notproton/lsteamclient; the manifest check reads notproton/app/.../valve-packages.manifest).

## D3DMetal is kept out of the tarball (applied)

D3DMetal was moved out of `assemble-runner.sh` into `scripts/install-d3dmetal.sh <runner>`:
- The script downloads GPTK 3.0-3 (SHA-256 pinned), shows Apple's licence and installs only after acceptance (interactive, or `D3DMETAL_ACCEPT_LICENSE=1`).
- `assemble-runner.sh` calls it unless `SKIP_D3DMETAL=1`, which this workflow sets.
- The installer runs the same script on the user's Mac (Phase 2, step 2).
- `runner.json` lists `"renderers": { "dxmt": "v0.80" }` until D3DMetal is added.

## Forbidden-content check
Fails if the assembled tree (or the final archive listing) has: D3DMetal*, libd3dshared*,
nvngx*, GPTK names, lib/external, lib/renderers/d3dmetal, runner.json mentioning d3dmetal;
steamclient.dll, steamclient64.dll, tier0_s64.dll, vstdlib_s64.dll, Steam.dll, SteamService.exe,
iscriptevaluator.exe, GameOverlayRenderer64.dll, a legacycompat dir, or any file whose sha256
equals a `file` entry in valve-packages.manifest. (Our own `lsteamclient.dll/.so` is distinct
and allowed; case-insensitive name match does not collide with it.)

## Other verified points
- MoltenVK: build-deps downloads MoltenVK v1.4.2 release tar, sha256-pinned, x86_64 verified.
- Wine Mono 10.4.1 and Gecko 2.47.4 (x86 + x86_64) are sha256-pinned and bundled by assemble.
- configure never gets `--with-opengl`; `--with-vulkan`, `--with-sdl`, `--with-ffmpeg` are set.
- All third-party actions are pinned by full SHA; release uses the preinstalled `gh`.
- ccache dir is `build/ccache` (build-wine.sh hardcodes CCACHE_DIR), cached keyed on
  hashFiles('patches/**','scripts/**'). Downloads under `downloads/` are not cached.

## Unverified
Rosetta on hosted arm64; total wall time vs 360 min timeout; that `brew install` on the image
provides the same versions as the local build; the workflow has only been YAML-parsed, not run.

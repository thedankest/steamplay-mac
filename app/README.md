# Steam Play (macOS app)

A SwiftUI front end for `scripts/install.sh` (Track 2). The engine does all the work; the app runs
it with `--json`, shows its steps and asks its questions in its own dialogs.

- **Status:** `install.sh doctor --json`, grouped into Steam, runner, fixes and installer checks,
  with Install, Repair, Re-apply, Uninstall and "Mark as handled" (journal-clear).
- **Questions:** when the engine exits 3 with `confirm` events, the app shows that exact text and,
  on yes, runs the same command again with `--confirmed-plan <token>`. It recomputes each token as
  sha256("<id>\n<text>") and refuses a mismatch. The D3DMetal licence is shown from the file the
  engine names; the app hashes that file when it shows it and passes the hash as
  `NP_D3DMETAL_LICENSE_TOKEN`, so only the text the user saw can be accepted.
- **Games:** prefixes in `compatdata` that ran through Steam Play, with play, run log and reveal.
- **Steam Backups:** `~/SteamPlayBackup`. The app never deletes backups.
- **Settings:** switches for every game in `global.env` (MSync, AVX, Metal HUD, launcher tile)
  and the engine folder.

The engine is found in this order: `STEAMPLAY_ENGINE`, the folder chosen in Settings, `engine/`
inside the app bundle (not built yet), `~/steamplay-mac`. NP_* path overrides are honoured the
same way the engine honours them.

## Build and test

```
app/build-app.sh --test      # unit + end-to-end tests, then app/dist/Steam Play.app (ad hoc)
```

Builds run at background priority with `-j4`. The package has no dependencies, so nothing is
downloaded. The end-to-end test drives the real `install.sh` in test mode against a fake
Steam.app (`Tests/fixtures/fake-world.sh`): install (licence, then plan), doctor, a declined
uninstall, then uninstall.

## Not yet

- Bundling the engine (scripts, autofix, signatures, notproton sources) inside the app.
- A Rosetta/FEX runner choice (waits for Runner B's Steam integration, T6).
- Sparkle updates, an icon, notarization.

# Mewgenics (686060). Sourced by compat_run.sh right before launch; helpers only:
# set_env, set_reg, dll_override, set_winver, edit_file. Every line is idempotent.
# Verified on Runner A (CrossOver 26.3 sources, Wine 11.0, Rosetta 2, macOS 27, M4) on 2026-10-09.

# The game asks for a GL 3.2+ context without WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB, which macOS
# refuses ("Could not create gl context"). CrossOver Hack 24834 in winemac.drv adds the bit.
set_env CX_FWD_COMPAT_GL_CTX 1

# Game speed is tied to the frame rate; with the framerate unlocked it runs at double speed.
# https://www.codeweavers.com/compatibility/crossover/tips/Mewgenics/fix-for-game-speed-issues
edit_file 'AppData/Roaming/Glaiel Games/Mewgenics/*/settings.txt' unlock_framerate false
edit_file 'AppData/Roaming/Glaiel Games/Mewgenics/*/settings.txt' vsync true

# Not needed here (audio was clean): Windows XP mode against crackling, reported for CrossOver 25/26.
# https://nerdschalk.com/play-mewgenics-on-mac-with-crossover-26-setup-mewgenics-with-compatibility-video-and-audio-fixes/
# set_winver Mewgenics.exe winxp

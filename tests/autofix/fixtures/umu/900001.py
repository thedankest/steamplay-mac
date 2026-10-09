"""Synthetic fixture modelled on umu-protonfixes game fixes (every mapping in one file)"""

import os

from protonfixes import util

_KEY = r'HKEY_CURRENT_USER\Software\Wine\DllOverrides'


def main() -> None:
    """Exercise every translator branch"""
    util.protontricks('vcrun2019')
    util.protontricks('physx')
    util.protontricks('directplay')
    util.protontricks('win7')
    util.protontricks('hidewineexports=enable')
    util.protontricks('sound=alsa')
    util.set_environment('WINE_DISABLE_SFN', '1')
    util.set_environment('PULSE_LATENCY_MSEC', '90')
    util.set_environment('PROTON_OLD_GL_STRING', '1')
    util.winedll_override('xaudio2_7', util.OverrideOrder.NATIVE)
    util.winedll_override('*dsound', util.OverrideOrder.BUILTIN)
    util.winedll_override('dinput8', util.OverrideOrder.NATIVE_BUILTIN)
    util.winedll_override('nvapi', util.OverrideOrder.DISABLED)
    util.wineexe_override('crashreporter', util.OverrideOrder.DISABLED)
    util.regedit_add('HKLM\\Software\\Wow6432Node\\Vendor')
    util.regedit_add(_KEY, 'dinput8', 'REG_SZ', 'native,builtin')
    util.regedit_add('HKCU\\Software\\Vendor\\Game', 'Name', 'REG_SZ', "It's here")
    util.append_argument('-dx11')
    util.append_argument('-fullscreen -vulkan')
    util.replace_command('Launcher.exe', 'Binaries/Win64/Game-Win64-Shipping.exe')
    util.replace_command(r'-launcher\s+', '')
    util.disable_esync()
    util.install_eac_runtime()
    util.set_cpu_topology_limit(8)
    util.set_ini_options('[Audio]\nVolume=80', 'Vendor/Game/config.ini', base_path=util.BasePath.USER)
    util.set_ini_options('[Video]\nWidth=1920', 'settings.ini')
    if os.path.exists('modorganizer2'):
        util.append_argument('-mo2')
    set_resolution()


def set_resolution() -> None:
    """Local helper, not translated"""
    util.set_environment('UNUSED', '1')

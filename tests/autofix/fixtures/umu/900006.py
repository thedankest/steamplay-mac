"""Synthetic fixture modelled on the Bethesda script-extender fixes (main_with_id)"""

import os

from protonfixes import util


def main_with_id(game_id: str) -> None:
    """Conditional replacement"""
    if os.path.isfile('skse_loader.exe'):
        util.replace_command('SkyrimLauncher.exe', 'skse_loader.exe')

"""Synthetic fixture: only Linux-specific knobs, nothing to translate"""

from protonfixes import util


def main() -> None:
    """Linux only"""
    util.disable_esync()
    util.disable_fsync()

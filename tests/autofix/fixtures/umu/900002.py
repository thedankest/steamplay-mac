"""Synthetic fixture: straight-line fix that translates fully"""

from protonfixes import util


def main() -> None:
    """Fully translatable"""
    util.set_environment('OPENSSL_ia32cap', ':~0x20000000')
    util.winedll_override('d3dcompiler_47', util.OverrideOrder.NATIVE_BUILTIN)
    util.protontricks('d3dx9_43')
    util.append_argument('-NoStartup')

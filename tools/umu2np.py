#!/usr/bin/env python3
"""umu2np.py: translate umu-protonfixes game fixes into notproton fix files.

    python3 -I tools/umu2np.py --out DIR [--verbs autofix/verbs.json] [--commit SHA]
                               [--report report.json] [--store steam] SRC...

SRC is a umu-protonfixes gamefixes-steam/ directory or single <appid>.py files. For every
<appid>.py the translator writes DIR/<appid>.sh, a fix file for compat_run.sh that uses only the
helper API (set_env, set_reg, dll_override, set_winver, edit_file) plus append_arg, replace_exe
(autofix/helpers.sh) and np_verb (autofix/verbs.sh).

The source is parsed with ast and never imported or executed. Only main() (or main_with_id())
is translated; straight-line calls with constant arguments are mapped, everything else (control
flow, helper functions, file I/O, unknown calls, unsupported verbs) becomes a "TODO(umu)"
comment so nothing is silently dropped. Linux-only knobs (esync/fsync/ntsync, Wayland, EAC and
BattlEye runtimes, Mesa/DXVK env) become "n/a" comments.

Per file status: full (every action mapped), partial (some mapped, some TODO), skipped (nothing
mapped; no .sh is written). The summary goes to stdout, details to --report.

umu-protonfixes is BSD-2-Clause, Copyright (c) 2018, Chris Simons; generated files carry that
notice in their header and autofix/NOTICE.umu-protonfixes keeps the full licence text.
"""

import ast
import json
import os
import re
import sys

REPO = 'https://github.com/Open-Wine-Components/umu-protonfixes'

OVERRIDE_MODES = {
    'NATIVE': 'native', 'BUILTIN': 'builtin', 'NATIVE_BUILTIN': 'native,builtin',
    'BUILTIN_NATIVE': 'builtin,native', 'DISABLED': '',
    'n': 'native', 'b': 'builtin', 'n,b': 'native,builtin', 'b,n': 'builtin,native', '': '',
}
WINVER_VERBS = {
    'win11', 'win10', 'win81', 'win8', 'win7', 'vista', 'win2008r2', 'win2008', 'win2003',
    'winxp', 'win2k', 'winme', 'win98', 'win95', 'nt40', 'nt351', 'win31', 'win30', 'win20',
}
# Proton options with no meaning outside Proton on Linux
PROTON_NA = {
    'PROTON_NO_ESYNC', 'PROTON_NO_FSYNC', 'PROTON_NO_NTSYNC', 'PROTON_USE_WAYLAND',
    'PROTON_ENABLE_WAYLAND', 'PROTON_ENABLE_NVAPI', 'PROTON_HIDE_NVIDIA_GPU',
    'PROTON_SET_GAME_DRIVE', 'PROTON_DLL_COPY', 'PROTON_ENABLE_HDR', 'PROTON_FSR4_UPGRADE',
    'PROTON_DLSS_UPGRADE', 'PROTON_XESS_UPGRADE', 'PROTON_USE_XALIA', 'PROTON_PREFER_SDL',
}
LINUX_ENV_PREFIXES = (
    '__GL_', 'MESA_', 'RADV_', 'DXVK_', 'VKD3D_', 'PULSE_', 'PIPEWIRE_', 'LD_', 'STAGING_',
    'GAMESCOPE', 'WINE_FULLSCREEN_FSR', 'vblank_mode', 'AMD_', 'INTEL_', 'NVIDIA_',
    'SteamDeck', 'SteamOS', 'mesa_',
)
NA_CALLS = {
    'disable_esync': 'esync is Linux-only (notproton uses msync)',
    'disable_fsync': 'fsync is Linux-only (notproton uses msync)',
    'disable_ntsync': 'ntsync is Linux-only (notproton uses msync)',
    'install_eac_runtime': 'EasyAntiCheat runtime: anti-cheat games are out of scope',
    'install_battleye_runtime': 'BattlEye runtime: anti-cheat games are out of scope',
    'disable_nvapi': 'no NVAPI on macOS',
    'set_game_drive': 'Proton game drive (S:) does not exist in notproton',
    'patch_libcuda': 'libcuda patch is Linux-only',
}
TODO_CALLS = {
    'set_cpu_topology_limit': 'CPU topology limit has no notproton equivalent yet',
    'set_cpu_topology_nosmt': 'CPU topology limit has no notproton equivalent yet',
    'set_cpu_topology': 'CPU topology limit has no notproton equivalent yet',
    'create_dos_device': 'extra DOS devices are not supported',
    'import_saves_folder': 'importing saves from another game is not supported',
    'set_dxvk_option': 'DXVK options are not used (DXMT/D3DMetal backends)',
    'set_xml_options': 'XML config edits are not representable with edit_file',
    'create_dosbox_conf': 'DOSBox config files are not supported',
    'del_environment': 'there is no helper to unset a variable',
    'install_all_from_tgz': 'downloads without a pinned hash are not allowed',
    'install_from_zip': 'downloads without a pinned hash are not allowed',
}
PURE_GETTERS = {
    'util.get_game_install_path', 'util.protonprefix', 'util.get_resolution',
    'util.get_steam_account_id', 'os.environ.get', 'os.getenv', 'os.path.join', 'Path', 'str',
    'int', 'glob.escape', 'util.protondir', 'util.which', 'util.checkinstalled',
    'util.is_custom_verb', 'util.get_cpu_count', 'util.is_smt_enabled', 'os.cpu_count',
}
LOG_CALLS = {'log', 'log.info', 'log.warn', 'log.debug', 'log.crit', 'log.err', 'print'}


class Unknown(Exception):
    pass


def q(s):
    s = str(s)
    if re.fullmatch(r'[A-Za-z0-9_.,:/=+@%-]+', s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return '.'.join(reversed(parts))
    return None


def comment_block(prefix, node):
    try:
        src = ast.unparse(node)
    except Exception:  # pragma: no cover
        src = '<unprintable>'
    lines = src.splitlines() or ['']
    out = ['# %s %s' % (prefix, lines[0])]
    out += ['#     %s' % line for line in lines[1:12]]
    if len(lines) > 12:
        out.append('#     ... (%d more lines)' % (len(lines) - 12))
    return out


class Translator:
    def __init__(self, known_verbs, commit=None):
        self.known_verbs = known_verbs
        self.commit = commit

    # -- constant folding ------------------------------------------------------------------
    def const(self, node, env):
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, int, float, bool)):
            return node.value
        if isinstance(node, ast.Name) and node.id in env:
            return env[node.id]
        if isinstance(node, ast.JoinedStr):
            out = []
            for v in node.values:
                if isinstance(v, ast.Constant):
                    out.append(str(v.value))
                elif isinstance(v, ast.FormattedValue) and v.format_spec is None and v.conversion == -1:
                    out.append(str(self.const(v.value, env)))
                else:
                    raise Unknown()
            return ''.join(out)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            a, b = self.const(node.left, env), self.const(node.right, env)
            if isinstance(a, str) and isinstance(b, str):
                return a + b
            raise Unknown()
        name = dotted(node)
        if name:
            last = name.rsplit('.', 1)[-1]
            if '.OverrideOrder.' in '.' + name and last in OVERRIDE_MODES:
                return ('OverrideOrder', last)
            if '.BasePath.' in '.' + name:
                return ('BasePath', last)
            if '.RegexFlag.' in '.' + name or name.startswith('re.'):
                return ('re', last)
        raise Unknown()

    def args(self, call, names, env):
        """Map positional + keyword args onto names; missing optional -> absent."""
        out = {}
        for i, a in enumerate(call.args):
            if isinstance(a, ast.Starred):
                raise Unknown()
            if i < len(names):
                out[names[i]] = self.const(a, env)
        for kw in call.keywords:
            if kw.arg is None:
                raise Unknown()
            out[kw.arg] = self.const(kw.value, env)
        return out

    # -- translation -----------------------------------------------------------------------
    def translate(self, tree):
        st = {'mapped': 0, 'todo': 0, 'na': 0, 'lines': [], 'notes': []}
        env = {}
        local_funcs = {}
        main = None
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                try:
                    env[node.targets[0].id] = self.const(node.value, env)
                except Unknown:
                    pass
            elif isinstance(node, ast.FunctionDef):
                if node.name in ('main', 'main_with_id'):
                    main = node
                else:
                    local_funcs[node.name] = node
        if main is None:
            st['todo'] += 1
            st['lines'].append('# TODO(umu): no main() found, nothing translated')
            return st
        if main.name == 'main_with_id':
            st['notes'].append('main_with_id(game_id): the game id is not known at translation time')
        body = main.body
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                and isinstance(body[0].value.value, str):
            doc = body[0].value.value.strip().splitlines()
            if doc:
                st['lines'].append('# umu: %s' % doc[0])
            body = body[1:]
        for stmt in body:
            self.statement(stmt, env, local_funcs, st)
        return st

    def statement(self, stmt, env, local_funcs, st):
        L = st['lines']
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
            return
        if isinstance(stmt, ast.Pass):
            return
        if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
            try:
                env[stmt.targets[0].id] = self.const(stmt.value, env)
                return
            except Unknown:
                pass
            calls = [dotted(n.func) for n in ast.walk(stmt.value) if isinstance(n, ast.Call)]
            env.pop(stmt.targets[0].id, None)
            if all(c in PURE_GETTERS for c in calls):
                L.extend(comment_block('umu (context, not translated):', stmt))
                return
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
            self.call(stmt.value, env, local_funcs, st)
            return
        st['todo'] += 1
        kind = type(stmt).__name__.lower()
        L.extend(comment_block('TODO(umu): %s not translated:' % kind, stmt))

    def call(self, call, env, local_funcs, st):
        L = st['lines']
        name = dotted(call.func) or ''
        short = name[5:] if name.startswith('util.') else None
        if name in LOG_CALLS:
            L.extend(comment_block('umu log:', call))
            return
        if name in local_funcs:
            st['todo'] += 1
            L.extend(comment_block('TODO(umu): local helper %s() not translated:' % name, call))
            return
        if short is None:
            st['todo'] += 1
            L.extend(comment_block('TODO(umu): unknown call:', call))
            return
        if short in NA_CALLS:
            st['na'] += 1
            L.append('# n/a: util.%s() - %s' % (short, NA_CALLS[short]))
            return
        if short in TODO_CALLS:
            st['todo'] += 1
            L.extend(comment_block('TODO(umu): %s:' % TODO_CALLS[short], call))
            return
        handler = getattr(self, 'h_' + short, None)
        if handler is None:
            st['todo'] += 1
            L.extend(comment_block('TODO(umu): unsupported util.%s():' % short, call))
            return
        try:
            handler(call, env, st)
        except Unknown:
            st['todo'] += 1
            L.extend(comment_block('TODO(umu): arguments not constant:', call))

    # -- util.* handlers -------------------------------------------------------------------
    def h_protontricks(self, call, env, st):
        verb = self.args(call, ['verb'], env)['verb']
        L = st['lines']
        if verb in self.known_verbs:
            L.append('np_verb %s' % q(verb))
            st['mapped'] += 1
        elif verb in WINVER_VERBS:
            ver = 'winxp64' if verb == 'winxp' else verb
            L.append("set_reg 'HKCU\\Software\\Wine' Version REG_SZ %s  # protontricks %s" % (q(ver), verb))
            st['mapped'] += 1
        elif verb == 'hidewineexports=enable':
            L.append("set_reg 'HKCU\\Software\\Wine' HideWineExports REG_SZ Y  # protontricks %s" % verb)
            st['mapped'] += 1
        elif verb.startswith('sound='):
            L.append('# n/a: protontricks %s - Linux audio driver selection' % verb)
            st['na'] += 1
        elif verb.startswith(('grabfullscreen=', 'usetakefocus=', 'fontsmooth=')):
            L.append('# n/a: protontricks %s - X11 driver setting' % verb)
            st['na'] += 1
        else:
            L.append('# TODO(umu): unsupported verb %s (not in autofix/verbs.json)' % verb)
            st['todo'] += 1

    def h_set_environment(self, call, env, st):
        a = self.args(call, ['envvar', 'value'], env)
        k, v = str(a['envvar']), str(a['value'])
        L = st['lines']
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', k):
            raise Unknown()
        if k in PROTON_NA or k.startswith(LINUX_ENV_PREFIXES):
            L.append('# n/a: set_env %s %s - Linux/Proton-only' % (k, q(v)))
            st['na'] += 1
        elif k == 'PROTON_USE_WINED3D':
            L.append('# TODO(umu): PROTON_USE_WINED3D=%s - the backend is chosen before fixes run; '
                     'use the launch option CX_GRAPHICS_BACKEND=wined3d' % v)
            st['todo'] += 1
        elif k.startswith('PROTON_'):
            L.append('# TODO(umu): set_env %s %s - Proton option without a notproton equivalent' % (k, q(v)))
            st['todo'] += 1
        else:
            L.append('set_env %s %s' % (k, q(v)))
            st['mapped'] += 1

    def _override(self, target, mode, st):
        if isinstance(mode, tuple):
            mode = mode[1]
        if mode not in OVERRIDE_MODES:
            raise Unknown()
        st['lines'].append('dll_override %s %s' % (q(target), q(OVERRIDE_MODES[mode]) if OVERRIDE_MODES[mode] else "''"))
        st['mapped'] += 1

    def h_winedll_override(self, call, env, st):
        a = self.args(call, ['dll', 'dtype'], env)
        self._override(str(a['dll']), a['dtype'], st)

    def h_wineexe_override(self, call, env, st):
        a = self.args(call, ['exe', 'dtype'], env)
        self._override(str(a['exe']) + '.exe', a['dtype'], st)

    def h_regedit_add(self, call, env, st):
        a = self.args(call, ['folder', 'name', 'typ', 'value', 'arch'], env)
        if a.get('name') is None or a.get('typ') is None or a.get('value') is None:
            st['lines'].append('# n/a: regedit_add %s - creates an empty key only, set_reg creates keys on demand' % q(a['folder']))
            st['na'] += 1
            return
        st['lines'].append('set_reg %s %s %s %s' % (q(a['folder']), q(a['name']), q(a['typ']), q(a['value'])))
        st['mapped'] += 1

    def h_append_argument(self, call, env, st):
        a = self.args(call, ['argument'], env)
        arg = str(a['argument'])
        parts = arg.split()
        if len(parts) > 1 and not re.search(r'[\'"]', arg):
            # umu appends one argv element with spaces; the game almost always wants the words
            st['lines'].append('# umu appends %s as one argument; split into words here' % q(arg))
            for p in parts:
                st['lines'].append('append_arg %s' % q(p))
        else:
            st['lines'].append('append_arg %s' % q(arg))
        st['mapped'] += 1

    def h_replace_command(self, call, env, st):
        a = self.args(call, ['orig', 'repl', 'match_flags'], env)
        orig, repl = str(a['orig']), str(a['repl'])
        flags = a.get('match_flags')
        if re.search(r'[\\^$*+?()\[\]{}|]', orig) or re.search(r'\\', repl) or \
                (flags is not None and flags != ('re', 'IGNORECASE')):
            st['lines'].append('# TODO(umu): replace_command %s %s - regex/flags not representable' % (q(orig), q(repl)))
            st['todo'] += 1
            return
        st['lines'].append('replace_exe %s %s' % (q(orig), q(repl)))
        st['mapped'] += 1

    def h_set_ini_options(self, call, env, st):
        a = self.args(call, ['ini_opts', 'cfile', 'encoding', 'base_path'], env)
        base = a.get('base_path', ('BasePath', 'GAME'))
        base = base[1] if isinstance(base, tuple) else str(base)
        root = {'USER': 'Documents', 'APPDATA_LOCAL': 'AppData/Local'}.get(base)
        L = st['lines']
        if root is None:
            L.append('# TODO(umu): set_ini_options on %s in the game folder - edit_file only reaches the prefix user profile' % q(a['cfile']))
            for line in str(a['ini_opts']).strip().splitlines():
                L.append('#     %s' % line.strip())
            st['todo'] += 1
            return
        path = '%s/%s' % (root, str(a['cfile']).lstrip('/'))
        L.append('# TODO(umu): set_ini_options is section-aware and adds missing keys; edit_file only '
                 'rewrites existing "key=value" lines in %s' % q(path))
        st['todo'] += 1
        for line in str(a['ini_opts']).splitlines():
            line = line.strip()
            if not line or line.startswith(('[', ';', '#')) or '=' not in line:
                continue
            key, val = (x.strip() for x in line.split('=', 1))
            if re.search(r'[/&\\|\n]', key + val) or not key:
                L.append('# TODO(umu): not representable for edit_file: %s' % line)
                continue
            L.append('edit_file %s %s %s' % (q(path), q(key), q(val)))
            st['mapped'] += 1


def load_verbs(path):
    with open(path, encoding='utf-8') as f:
        return set(json.load(f).get('verbs', {}))


def header(appid, rel, src_rel, commit, status, st, alias_of):
    url = '%s/blob/%s/%s' % (REPO, commit or 'master', src_rel)
    out = [
        '# shellcheck shell=sh',
        '# Steam app %s: generated by tools/umu2np.py from umu-protonfixes %s' % (appid, rel),
        '# Source: %s' % url,
        '# Upstream commit: %s' % (commit or 'unknown'),
        '# Licence: BSD-2-Clause, Copyright (c) 2018, Chris Simons (umu-protonfixes);',
        '#          full text in autofix/NOTICE.umu-protonfixes',
        '# Translation: %s (mapped %d, todo %d, n/a %d). Do not edit; put local changes in fixes/%s.sh.'
        % (status, st['mapped'], st['todo'], st['na'], appid),
    ]
    if alias_of:
        out.append('# Upstream file is a symlink to %s' % alias_of)
    for n in st['notes']:
        out.append('# Note: %s' % n)
    return out


def translate_file(path, tr, store):
    real = os.path.realpath(path)
    alias_of = os.path.basename(real) if os.path.islink(path) else None
    with open(real, encoding='utf-8') as f:
        src = f.read()
    try:
        tree = ast.parse(src, filename=path)
    except SyntaxError as e:
        return {'status': 'error', 'error': 'syntax error: %s' % e, 'alias_of': alias_of}, None
    st = tr.translate(tree)
    if st['mapped'] == 0:
        status = 'skipped'
    elif st['todo'] == 0:
        status = 'full'
    else:
        status = 'partial'
    info = {'status': status, 'mapped': st['mapped'], 'todo': st['todo'], 'na': st['na'],
            'alias_of': alias_of}
    if status == 'skipped':
        return info, None
    appid = os.path.splitext(os.path.basename(path))[0]
    rel = 'gamefixes-%s/%s' % (store, os.path.basename(path))
    text = '\n'.join(header(appid, rel, rel, tr.commit, status, st, alias_of) + [''] + st['lines']) + '\n'
    return info, text


def main(argv):
    out_dir = None
    verbs = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'autofix', 'verbs.json')
    commit = None
    report = None
    store = 'steam'
    srcs = []
    it = iter(argv)
    for a in it:
        if a == '--out':
            out_dir = next(it, None)
        elif a == '--verbs':
            verbs = next(it, None)
        elif a == '--commit':
            commit = next(it, None)
        elif a == '--report':
            report = next(it, None)
        elif a == '--store':
            store = next(it, 'steam')
        else:
            srcs.append(a)
    if not out_dir or not srcs:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    tr = Translator(load_verbs(verbs), commit)
    files = []
    for s in srcs:
        if os.path.isdir(s):
            files += [os.path.join(s, f) for f in sorted(os.listdir(s))
                      if re.fullmatch(r'\d+\.py', f)]
        else:
            files.append(s)
    os.makedirs(out_dir, exist_ok=True)
    results = {}
    for f in files:
        appid = os.path.splitext(os.path.basename(f))[0]
        info, text = translate_file(f, tr, store)
        results[appid] = info
        if text is not None:
            with open(os.path.join(out_dir, appid + '.sh'), 'w', encoding='utf-8') as o:
                o.write(text)
    counts = {}
    for info in results.values():
        counts[info['status']] = counts.get(info['status'], 0) + 1
    total = len(results)
    print('umu2np: %d files: %s' % (total, ', '.join('%s %d' % (k, counts.get(k, 0))
                                                       for k in ('full', 'partial', 'skipped', 'error'))))
    if report:
        with open(report, 'w', encoding='utf-8') as o:
            json.dump({'commit': commit, 'counts': counts, 'files': results}, o, indent=1, sort_keys=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

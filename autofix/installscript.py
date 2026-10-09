#!/usr/bin/env python3
"""installscript.py: read a Steam installscript.vdf (text KeyValues) and map its redists to verbs.

    python3 -I installscript.py [--install-dir DIR] [--verbs verbs.json] [--json|--sh] FILE.vdf

Each "Run Process" block becomes one redist entry with a kind (vcredist, directx, physx,
ue3redist, dotnet, xna, openal, custom), the verbs from autofix/verbs.json that satisfy it, a
policy, and its HasRunKey:

  auto      install the verb when its payload is missing (vcredist, physx, ue3redist)
  optional  only with NOTPROTON_AUTOFIX_REDIST=all (DirectX: Wine's builtin d3dx9 usually does;
            .NET/XNA: Wine Mono usually does, and .NET takes 20-40 minutes)
  none      no verb, Steam's own run (or another autofix rule) has to cover it

--sh prints one tab-separated line per verb: verb, policy, kind, block name, HasRunKey
("-" as verb when nothing maps). --json (default) prints everything, Registry entries included.
The run script decides "installed" by the verb's payload, not by HasRunKey: Steam writes that
key even when the installer failed (Alien Breed 3, InstallShield error 1628).

Parsing only; never executes anything. Standard library only.
"""

import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


# ---- KeyValues text parser ------------------------------------------------------------------

def tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n﻿':
            i += 1
        elif c == '/' and text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j + 1
        elif c in '{}':
            yield c
            i += 1
        elif c == '[':
            # conditional such as [$WIN32]; ignored
            j = text.find(']', i)
            i = n if j < 0 else j + 1
        elif c == '"':
            i += 1
            out = []
            while i < n and text[i] != '"':
                if text[i] == '\\' and i + 1 < n:
                    nxt = text[i + 1]
                    if nxt in '\\"':
                        out.append(nxt)
                        i += 2
                        continue
                    if nxt == 'n':
                        out.append('\n')
                        i += 2
                        continue
                    if nxt == 't':
                        out.append('\t')
                        i += 2
                        continue
                out.append(text[i])
                i += 1
            i += 1
            yield ('s', ''.join(out))
        else:
            j = i
            while j < n and text[j] not in ' \t\r\n{}"':
                j += 1
            yield ('s', text[i:j])
            i = j


def parse(text):
    """Return a list of (key, value) pairs; value is a str or a nested list."""
    toks = list(tokenize(text))
    pos = 0

    def block():
        nonlocal pos
        items = []
        while pos < len(toks):
            t = toks[pos]
            if t == '}':
                pos += 1
                return items
            if t == '{':
                # anonymous block, keep its content
                pos += 1
                items.append(('', block()))
                continue
            key = t[1]
            pos += 1
            if pos >= len(toks):
                items.append((key, ''))
                break
            v = toks[pos]
            if v == '{':
                pos += 1
                items.append((key, block()))
            elif v == '}':
                items.append((key, ''))
            else:
                pos += 1
                items.append((key, v[1]))
        return items

    return block()


def get(items, key):
    for k, v in items:
        if k.lower() == key.lower():
            return v
    return None


# ---- classification -------------------------------------------------------------------------

VC_YEARS = {'8': '2005', '9': '2008', '10': '2010', '11': '2012', '12': '2013', '14': '2022'}


def load_pe_version():
    sys.dont_write_bytecode = True  # no __pycache__ next to the installed autofix files
    path = os.path.join(HERE, 'pe_version.py')
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location('np_pe_version', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def resolve(process, install_dir):
    if not process:
        return None
    p = re.sub(r'(?i)%INSTALLDIR%', lambda _: install_dir, process).replace('\\', '/')
    if os.path.exists(p):
        return p
    # Windows paths are case-insensitive; walk the parts
    parts = [x for x in p[len(install_dir):].split('/') if x] if p.startswith(install_dir) else None
    if parts is None:
        return None
    cur = install_dir
    for part in parts:
        try:
            match = next((e for e in os.listdir(cur) if e.lower() == part.lower()), None)
        except OSError:
            return None
        if match is None:
            return None
        cur = os.path.join(cur, match)
    return cur


def vc_year(text, exe_path, pev):
    m = re.search(r'(?<!\d)20(05|08|10|12|13|15|17|19|22)(?!\d)', text)
    if m:
        y = '20' + m.group(1)
        return '2022' if y in ('2015', '2017', '2019') else y
    if exe_path and pev:
        try:
            info = pev.strings(exe_path)
        except Exception:
            info = {}
        ver = info.get('ProductVersion') or info.get('FileVersion') or ''
        major = re.split(r'[.,\s]', ver.strip(), maxsplit=1)[0] if ver else ''
        return VC_YEARS.get(major)
    return None


def classify(name, processes, install_dir, pev):
    text = ' '.join([name] + processes).lower()
    paths = [resolve(p, install_dir) for p in processes]
    if 'ue3redist' in text:
        return 'ue3redist', ['physx'], ['d3dx9'], 'auto'
    if 'physx' in text:
        return 'physx', ['physx'], [], 'auto'
    if re.search(r'vc_?redist|vcredist|msvc', text):
        years = []
        for p, rp in zip(processes, paths):
            y = vc_year(name + ' ' + p, rp, pev)
            if y and 'vcrun' + y not in years:
                years.append('vcrun' + y)
        if not years:
            y = vc_year(name, None, None)
            if y:
                years.append('vcrun' + y)
        return 'vcredist', years, [], 'auto'
    if 'dxsetup' in text or 'directx' in text or re.search(r'\bdx\w*redist', text):
        return 'directx', [], ['d3dx9'], 'optional'
    if re.search(r'ndp4[6-8]|dotnetfx4[6-8]|net4[6-8]|dotnet4[6-8]', text):
        return 'dotnet', [], ['dotnet48'], 'optional'
    if re.search(r'dotnetfx40|ndp40|dotnet40|net40', text):
        return 'dotnet', [], ['dotnet40'], 'optional'
    if 'dotnet' in text or 'netfx' in text:
        return 'dotnet', [], [], 'none'
    if 'xnafx40' in text or 'xna 4' in text or 'xna40' in text:
        return 'xna', [], ['xna40'], 'optional'
    if 'xna' in text:
        return 'xna', [], [], 'none'
    if 'oalinst' in text or 'openal' in text:
        return 'openal', [], [], 'none'
    return 'custom', [], [], 'none'


def analyse(vdf_path, install_dir=None, verbs_path=None):
    with open(vdf_path, 'r', encoding='utf-8', errors='replace') as f:
        tree = parse(f.read())
    root = get(tree, 'InstallScript')
    if not isinstance(root, list):
        root = tree
    install_dir = os.path.abspath(install_dir or os.path.dirname(os.path.abspath(vdf_path)))
    known = set()
    vp = verbs_path or os.path.join(HERE, 'verbs.json')
    try:
        with open(vp, encoding='utf-8') as f:
            known = set(json.load(f).get('verbs', {}))
    except (OSError, ValueError):
        pass
    pev = load_pe_version()

    redists = []
    for section, blocks in root:
        if section.lower() != 'run process' or not isinstance(blocks, list):
            continue
        for name, body in blocks:
            if not isinstance(body, list):
                continue
            processes, commands = [], []
            for k, v in body:
                if isinstance(v, str) and re.fullmatch(r'(?i)process\s*\d+', k):
                    processes.append(v)
                elif isinstance(v, str) and re.fullmatch(r'(?i)command\s*\d+', k):
                    commands.append(v)
            kind, verbs, optional, policy = classify(name, processes, install_dir, pev)
            unknown = [v for v in verbs + optional if known and v not in known]
            verbs = [v for v in verbs if not known or v in known]
            optional = [v for v in optional if not known or v in known]
            redists.append({
                'name': name,
                'kind': kind,
                'policy': policy if (verbs or optional) else 'none',
                'verbs': verbs,
                'optional_verbs': optional,
                'unknown_verbs': unknown,
                'processes': processes,
                'commands': commands,
                'hasrunkey': get(body, 'HasRunKey') or '',
                'minimum_hasrun_value': get(body, 'MinimumHasRunValue') or '',
            })

    registry = []
    reg = get(root, 'Registry')
    if isinstance(reg, list):
        for key, types in reg:
            if not isinstance(types, list):
                continue
            for typ, values in types:
                if isinstance(values, list):
                    for vname, val in values:
                        if isinstance(val, str):
                            registry.append({'key': key, 'type': typ, 'name': vname, 'value': val})
    return {'file': os.path.abspath(vdf_path), 'install_dir': install_dir,
            'redists': redists, 'registry': registry}


def clean(s):
    return re.sub(r'[\t\r\n]+', ' ', s or '').strip()


def main(argv):
    mode = 'json'
    install_dir = verbs = None
    files = []
    it = iter(argv)
    for a in it:
        if a == '--sh':
            mode = 'sh'
        elif a == '--json':
            mode = 'json'
        elif a == '--install-dir':
            install_dir = next(it, None)
        elif a == '--verbs':
            verbs = next(it, None)
        else:
            files.append(a)
    if not files:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    results = []
    for f in files:
        try:
            results.append(analyse(f, install_dir, verbs))
        except (OSError, UnicodeError) as e:
            print('installscript: %s: %s' % (f, e), file=sys.stderr)
            return 1
    if mode == 'json':
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
        return 0
    for r in results:
        for d in r['redists']:
            lines = [(v, d['policy'] if d['policy'] == 'auto' else 'optional') for v in d['verbs']]
            lines += [(v, 'optional') for v in d['optional_verbs']]
            if not lines:
                lines = [('-', 'none')]
            for v, pol in lines:
                print('\t'.join([v, pol, d['kind'], clean(d['name']), clean(d['hasrunkey']) or '']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

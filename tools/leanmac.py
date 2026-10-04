#!/usr/bin/env python3
"""Read-only Hangar diagnostics and recoverable configuration installs."""
import argparse
import concurrent.futures
import contextlib
import ctypes
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import tomllib

VERSION = '2026.10.04.3'
USER_DIR = Path.home()
# Stable storage namespace shared with existing LeanMac installations.
STATE = USER_DIR / 'Library/Application Support/LeanMac'
CONFIG = USER_DIR / '.aerospace.toml'
HS_DIR = USER_DIR / '.hammerspoon'
LUA_FILES = ('leanmac.lua', 'window-picker.lua', 'window-snap.lua', 'spaces-sync.lua',
             'mx-buttons.lua', 'leanmac-runtime.lua', 'leanmac-health.lua', 'leanmac-palette.lua', 'window-groups.lua',
             'window-links.lua', 'workspace-overview.lua', 'picker-panel.lua', 'hangar-config.lua')
HS_APP = Path('/Applications/Hammerspoon.app')
HS = str(HS_APP / 'Contents/Frameworks/hs/hs')
AERO = '/opt/homebrew/bin/aerospace' if Path('/opt/homebrew/bin/aerospace').exists() else '/usr/local/bin/aerospace'
ENV = dict(os.environ, PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
SNAPSHOT = """local m=rawget(_G,'leanmac'); local s
if m and m.health then s=m.health.snapshot() else
s={accessibility=hs.accessibilityState(),secureInput=hs.eventtap.isSecureInputEnabled(),loaded=m~=nil}
if m then local p=m.picker or {}; local k=m.snap or {}; local x=m.mx or {}
s.pickerSubscriber=p.subscriber~=nil and p.subscriber:isRunning()
s.pickerForward=p.forward~=nil and p.forward.enabled==true
s.pickerBackward=p.backward~=nil and p.backward.enabled==true
s.pickerSearch=p.search~=nil and p.search.enabled==true
s.snapKeys=k.left~=nil and k.left.enabled and k.right~=nil and k.right.enabled and k.up~=nil and k.up.enabled and k.down~=nil and k.down.enabled
s.snapMouse=k.mouse~=nil and k.mouse:isEnabled()
s.mxPicker=x.picker~=nil and x.picker.enabled==true end end
print('LEANMAC_JSON:'..hs.json.encode(s))"""


def run(args, timeout=5, required=False):
    try:
        p = subprocess.run([str(x) for x in args], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=timeout, env=ENV)
        result = (p.returncode, p.stdout.strip(), p.stderr.strip())
    except (OSError, subprocess.TimeoutExpired) as e:
        result = (124 if isinstance(e, subprocess.TimeoutExpired) else 127, '', str(e))
    if required and result[0]:
        raise RuntimeError(f'{Path(str(args[0])).name}: {result[2] or result[1]}')
    return result


def hs_snapshot():
    code, out, err = run([HS, '-t', '3', '-c', SNAPSHOT], timeout=5)
    for line in out.splitlines():
        if line.startswith('LEANMAC_JSON:'):
            return json.loads(line.removeprefix('LEANMAC_JSON:'))
    raise RuntimeError(err or out or f'Hammerspoon IPC unavailable ({code})')


def selected_profile():
    selector = STATE / 'aerospace-profile'
    profile = selector.read_text().strip() if selector.exists() else 'default'
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', profile):
        raise ValueError('Invalid local aerospace-profile selector')
    return profile


# Portable desired configuration is separate from the activated runtime and backups.
DEFAULT_HOTKEYS = {
    'terminal': 'ctrl-alt-cmd-return', 'browser': 'ctrl-alt-cmd-b', 'finder': 'ctrl-alt-cmd-e',
    'menu_bar': 'ctrl-alt-cmd-m', 'menu_search': 'ctrl-alt-cmd-p', 'reload': 'ctrl-alt-cmd-r',
    'management_toggle': 'ctrl-alt-cmd-escape', 'picker_search': 'ctrl-alt-cmd-w',
    'snap_left': 'alt-left', 'snap_right': 'alt-right', 'snap_up': 'alt-up', 'snap_down': 'alt-down',
    'pair': 'alt-p', 'separate': 'alt-shift-p', 'layout_menu': 'alt-g', 'overview': 'alt-o',
    'palette': 'ctrl-alt-cmd-slash', 'gather': 'ctrl-alt-cmd-s', 'mx_picker': 'f17',
}
PORTABLE_APPS = {'terminal': 'Terminal', 'browser': 'Safari', 'finder': 'Finder'}
LEGACY_APPS = {'terminal': 'Ghostty', 'browser': 'Brave Browser', 'finder': 'Finder'}
MODIFIERS = ('ctrl', 'alt', 'cmd', 'shift')
KEY_NAMES = {name: name for name in ('return', 'tab', 'space', 'escape', 'left', 'right', 'up', 'down')}
KEY_NAMES.update({'slash': '/', 'comma': ',', 'period': '.', 'backtick': '`', 'minus': '-', 'equal': '='})
KEY_NAMES.update({key: key for key in 'abcdefghijklmnopqrstuvwxyz0123456789'})
KEY_NAMES.update({f'f{i}': f'f{i}' for i in range(1, 21)})


def xdg_config_root():
    root = Path(os.environ.get('XDG_CONFIG_HOME') or USER_DIR / '.config')
    if not root.is_absolute():
        raise ValueError('XDG_CONFIG_HOME must be an absolute path')
    return Path(os.path.abspath(root))


def user_config_dir():
    return xdg_config_root() / 'hangar'


def parse_hotkey(chord):
    if not isinstance(chord, str):
        raise ValueError('Hotkeys must be chord strings, such as ctrl-alt-cmd-return')
    parts = chord.lower().split('-')
    modifiers, key = parts[:-1], parts[-1]
    if key not in KEY_NAMES or len(set(modifiers)) != len(modifiers) or any(m not in MODIFIERS for m in modifiers):
        raise ValueError(f'Unsupported hotkey: {chord}')
    canonical = '-'.join([m for m in MODIFIERS if m in modifiers] + [key])
    return canonical, {'mods': [m for m in MODIFIERS if m in modifiers], 'key': KEY_NAMES[key]}


def read_user_settings(path):
    if path.stat().st_size > 64 * 1024:
        raise ValueError(f'Settings exceed 64 KiB: {path}')
    values = tomllib.loads(path.read_text())
    unknown = values.keys() - {'schema', 'profile', 'apps', 'hotkeys'}
    if unknown:
        raise ValueError(f'{path.name}: unknown settings: {", ".join(sorted(unknown))}')
    if 'schema' in values and (type(values['schema']) is not int or values['schema'] != 1):
        raise ValueError(f'{path.name}: schema must be integer 1')
    if 'profile' in values and (not isinstance(values['profile'], str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]*', values['profile'])):
        raise ValueError(f'{path.name}: invalid profile')
    for section, allowed in [('apps', PORTABLE_APPS), ('hotkeys', DEFAULT_HOTKEYS)]:
        if section not in values:
            continue
        entries = values[section]
        if not isinstance(entries, dict) or entries.keys() - allowed.keys():
            raise ValueError(f'{path.name}: unknown or invalid {section} settings')
        for key, value in entries.items():
            if not isinstance(value, str) or not value.strip() or len(value) > 160 or any(ord(c) < 32 for c in value):
                raise ValueError(f'{path.name}: {section}.{key} must be a nonempty string without control characters')
            if section == 'hotkeys':
                parse_hotkey(value)
    return values


def resolve_user_config(kit=None):
    directory = user_config_dir()
    sources = {'settings': None, 'local': None, 'aerospace': None, 'profile': 'legacy-selector' if (STATE / 'aerospace-profile').exists() else 'default'}
    merged = {}
    for name, source_key in [('settings.toml', 'settings'), ('settings.local.toml', 'local')]:
        path = directory / name
        if not path.exists() and not path.is_symlink():
            continue
        values = read_user_settings(path)
        sources[source_key] = str(path)
        for key, value in values.items():
            if key in ('apps', 'hotkeys'):
                merged.setdefault(key, {}).update(value)
            else:
                merged[key] = value
            if key == 'profile':
                sources['profile'] = str(path)
    configured = sources['settings'] is not None or sources['local'] is not None
    profile = merged['profile'] if 'profile' in merged else selected_profile()
    apps = {**(PORTABLE_APPS if configured else LEGACY_APPS), **merged.get('apps', {})}
    hotkeys = {**DEFAULT_HOTKEYS, **merged.get('hotkeys', {})}
    seen = {'alt-tab': 'reserved picker cycling', 'alt-shift-tab': 'reserved reverse picker cycling'}
    runtime_keys = {}
    for action, chord in hotkeys.items():
        canonical, runtime = parse_hotkey(chord)
        if canonical in seen:
            raise ValueError(f'Hotkey collision: {action} and {seen[canonical]} both use {canonical}')
        seen[canonical], hotkeys[action], runtime_keys[action] = action, canonical, runtime
    override = directory / 'aerospace.toml'
    if override.exists() or override.is_symlink():
        sources['aerospace'] = str(override)
    elif kit is not None:
        sources['aerospace'] = str(Path(kit).resolve() / 'config' / ('aerospace.toml' if profile == 'default' else f'aerospace-{profile}.toml'))
    return {'schema': 1, 'profile': profile, 'apps': apps, 'hotkeys': hotkeys,
            'sources': sources, 'legacy_defaults': not configured, 'runtime_hotkeys': runtime_keys}


def validate_user_config(config):
    source = config['sources']['aerospace']
    if source is None:
        raise RuntimeError('No AeroSpace source available. Pass --kit /path/to/Hangar or provide ~/.config/hangar/aerospace.toml')
    candidate = Path(source)
    if not candidate.is_file():
        raise RuntimeError(f'Selected profile does not exist: {candidate}')
    aerospace = validate_config(candidate)
    owned = {parse_hotkey(chord)[0]: action for action, chord in config['hotkeys'].items()}
    owned.update({'alt-tab': 'picker cycling', 'alt-shift-tab': 'reverse picker cycling'})
    # Compare ordinary AeroSpace chords in every mode; unsupported AeroSpace syntax is
    # validated by AeroSpace during activation, never guessed by this layer.
    for mode, body in aerospace.get('mode', {}).items():
        for chord in body.get('binding', {}):
            try:
                parts = chord.split('-')
                parts[-1] = {'enter': 'return', 'esc': 'escape'}.get(parts[-1], parts[-1])
                canonical, _ = parse_hotkey('-'.join(parts))
            except ValueError:
                continue
            if canonical in owned:
                raise ValueError(f'Hotkey collision: AeroSpace {mode}:{chord} conflicts with Hangar {owned[canonical]}')
    return aerospace


def lua_literal(value):
    if isinstance(value, str):
        # Lua accepts quoted UTF-8 and these escapes; inputs have no control bytes.
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        return '{' + ','.join('[' + lua_literal(k) + ']=' + lua_literal(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '{' + ','.join(lua_literal(v) for v in value) + '}'
    raise ValueError('Unsupported generated settings value')


def render_runtime_settings(config):
    return '-- Generated by Hangar; edit ~/.config/hangar/settings.toml and apply.\nreturn ' + lua_literal({'apps': config['apps'], 'hotkeys': config['runtime_hotkeys']}) + '\n'


def init_user_config():
    directory = user_config_dir()
    # Neither source is overwritten; existing local-only settings are deliberate.
    for name in ('settings.toml', 'settings.local.toml'):
        if (directory / name).exists() or (directory / name).is_symlink():
            raise RuntimeError(f'Configuration already exists: {directory / name}')
    directory.mkdir(parents=True, exist_ok=True)
    text = '# Hangar portable settings. No activation until config apply.\n'
    text += '# Omit profile to retain the legacy selector; or use default / numbered-study.\nschema = 1\n\n[apps]\n'
    text += '\n'.join(f'{key} = {json.dumps(value)}' for key, value in PORTABLE_APPS.items()) + '\n'
    target = directory / 'settings.toml'
    with target.open('x') as stream:
        stream.write(text)
    print(f'Created {target}. Review with hangar config show; validate with hangar config check.')


def check_user_config(config):
    validate_user_config(config)
    if (HS_APP / 'Contents/Frameworks/LuaSkin.framework/LuaSkin').exists():
        with tempfile.TemporaryDirectory(prefix='hangar-config-check-') as directory:
            target = Path(directory) / 'hangar-settings.lua'
            target.write_text(render_runtime_settings(config))
            validate_lua([target])
        print('Configuration valid: TOML, profile, shortcut ownership, generated Lua syntax. No activation.')
    else:
        print('Configuration valid: TOML, profile and shortcut ownership. Lua syntax check unavailable without Hammerspoon. No activation.')


def json_result(result):
    code, out, err = result
    if code:
        raise RuntimeError(err or out or 'Command failed')
    return json.loads(out)


def doctor():
    report = {'version': VERSION, 'machine': socket.gethostname(), 'checks': [],
              'checkedAt': dt.datetime.now().astimezone().isoformat(timespec='seconds')}
    def add(name, status, message):
        report['checks'].append({'name': name, 'status': status, 'message': message})
    try:
        report['profile'] = resolve_user_config(default_kit())['profile']
        add('profile', 'ok', f"Configured source profile: {report['profile']}")
    except (OSError, ValueError) as e:
        add('profile', 'fail', str(e))
    config = {}
    try:
        config = tomllib.loads(CONFIG.read_text())
        add('config-file', 'ok', f'Config parses: {CONFIG}')
    except (OSError, ValueError) as e:
        add('config-file', 'fail', f'Config cannot be read/parsed: {e}')
    xdg = xdg_config_root() / 'aerospace/aerospace.toml'
    if xdg.exists():
        add('config-location', 'fail', f'Second AeroSpace config exists: {xdg}')
    jobs = {
        'monitors': lambda: json_result(run([AERO, 'list-monitors', '--json'])),
        'workspaces': lambda: json_result(run([AERO, 'list-workspaces', '--all', '--format',
            '%{workspace} %{monitor-name} %{workspace-is-visible}', '--json'])),
        'bindings': lambda: json_result(run([AERO, 'config', '--get', 'mode.main.binding', '--json'])),
        'strict': lambda: run([AERO, 'reload-config', '--dry-run', '--warnings-as-errors', '--no-gui']),
        'config-path': lambda: run([AERO, 'config', '--config-path']),
        'mode': lambda: run([AERO, 'list-modes', '--current']),
        'hs': hs_snapshot,
    }
    values, errors = {}, {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as pool:
        pending = {pool.submit(fn): name for name, fn in jobs.items()}
        for future in concurrent.futures.as_completed(pending):
            name = pending[future]
            try:
                values[name] = future.result()
            except Exception as e:
                errors[name] = str(e)
    if 'monitors' in values:
        report['monitors'] = values['monitors']
        add('aerospace', 'ok', f"AeroSpace responds; {len(values['monitors'])} display(s)")
    else:
        add('aerospace', 'fail', 'AeroSpace is unavailable: ' + errors.get('monitors', 'unknown error'))
    if 'workspaces' in values:
        report['workspaces'] = values['workspaces']
        mapping = ', '.join(f"{w['workspace']} → {w.get('monitor-name', '?')}" for w in values['workspaces'])
        add('mapping', 'ok', mapping or 'No workspaces')
    else:
        add('mapping', 'fail', 'Workspace mapping unavailable: ' + errors.get('workspaces', 'unknown error'))
    strict = values.get('strict', (1, '', 'Unavailable'))
    add('strict-config', 'ok' if strict[0] == 0 else 'fail',
        'AeroSpace strict validation passed' if strict[0] == 0 else 'AeroSpace config validation: ' + (strict[2] or strict[1]))
    loaded = values.get('config-path', (1, '', ''))
    if loaded[0] == 0:
        add('active-config', 'ok' if Path(loaded[1]).resolve() == CONFIG.resolve() else 'fail', 'Loaded config: ' + loaded[1])
    bindings = values.get('bindings', {})
    expected = config.get('mode', {}).get('main', {}).get('binding', {})
    missing = [k for k, v in expected.items() if bindings.get(k) != ('; '.join(v) if isinstance(v, list) else v)]
    add('bindings', 'ok' if expected and not missing else 'fail',
        f'{len(expected)} AeroSpace bindings match disk' if expected and not missing else 'AeroSpace bindings differ or are missing: ' + ', '.join(missing))
    mode = values.get('mode', (1, '', ''))
    if mode[0] == 0:
        add('binding-mode', 'ok' if mode[1] == 'main' else 'warn', f'Current AeroSpace binding mode: {mode[1]}')
    state = values.get('hs', {})
    report['hammerspoon'] = state
    if not state:
        add('hammerspoon', 'fail', 'Hammerspoon IPC unavailable: ' + errors.get('hs', 'unknown error'))
    else:
        for key, message in [('accessibility', 'Hammerspoon Accessibility'), ('loaded', 'Hangar modules loaded'),
                             ('pickerSubscriber', 'Window picker event subscription'), ('pickerForward', 'Option+Tab'),
                             ('pickerBackward', 'Option+Shift+Tab'), ('pickerSearch', 'Search picker'),
                             ('snapKeys', 'Configured snapping shortcuts'), ('snapMouse', 'Drag snapping'),
                             ('mxPicker', 'MX picker button'), ('paletteKey', 'Command palette shortcut'),
                             ('healthWatcher', 'Wake/unlock watcher'), ('groupKeys', 'Pair/separate/layout shortcuts'),
                             ('overviewKey', 'Workspace overview shortcut')]:
            add(key, 'ok' if state.get(key) else 'fail', message + (' ready' if state.get(key) else ' unavailable'))
        add('pickerPanel', 'ok' if state.get('pickerPanel') else 'fail',
            'Native window panel ready' if state.get('pickerPanel') else 'Native window panel unavailable')
        if state.get('nativeRouterLoaded'):
            add('native-router', 'fail', 'Experimental hotkey router is loaded')
        if state.get('spacesError'):
            add('desktops', 'warn', 'Could not inspect native Desktops: ' + state['spacesError'])
        elif state.get('extraDesktops') is not None:
            n = state['extraDesktops']
            add('desktops', 'warn' if n else 'ok', f'{n} extra macOS Desktop(s)' if n else 'One native Desktop per display')
    secure = state.get('secureInput')
    if secure is None:
        try:
            carbon = ctypes.CDLL('/System/Library/Frameworks/Carbon.framework/Carbon')
            carbon.IsSecureEventInputEnabled.restype = ctypes.c_bool
            secure = bool(carbon.IsSecureEventInputEnabled())
        except (OSError, AttributeError):
            pass
    report['secureInput'] = secure
    if secure:
        _, registry, _ = run(['/usr/sbin/ioreg', '-l', '-w', '0'], timeout=5)
        pids = sorted(set(re.findall(r'"kCGSSessionSecureInputPID"\s*=\s*(\d+)', registry)))
        owners = []
        for pid in pids:
            code, name, _ = run(['/bin/ps', '-p', pid, '-o', 'comm='])
            owners.append({'pid': int(pid), 'process': name if code == 0 else 'stale/exited PID'})
        report['secureInputOwners'] = owners
        label = ', '.join(f"{Path(o['process']).name} ({o['pid']})" for o in owners) or 'owner not exposed by macOS'
        add('secure-input', 'warn', f'Secure Input active; macOS reports {label}. Leave password fields; unlock 1Password if locked. Attribution can be stale.')
    elif secure is False:
        add('secure-input', 'ok', 'Secure Input is off')
    else:
        add('secure-input', 'warn', 'Secure Input status unavailable')
    _, processes, _ = run(['/bin/ps', '-axo', 'comm='])
    native = any(Path(p.strip()).name == 'leanmac-hotkeys' for p in processes.splitlines())
    native_plist = USER_DIR / 'Library/LaunchAgents/local.leanmac.hotkeys.plist'
    native_service = run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/local.leanmac.hotkeys'])[0] == 0
    add('native-helper', 'fail' if native or native_service or native_plist.exists() else 'ok',
        'Experimental native hotkey helper is active or installed' if native or native_service or native_plist.exists() else 'Experimental native hotkey helper stays disabled')
    if any(Path(p.strip()).name == 'AltTab' for p in processes.splitlines()):
        add('alttab', 'warn', 'AltTab is running and may conflict with Option+Tab')
    helper = HS_DIR / 'bin/leanmac-window-focus'
    code, _, err = run(['/usr/bin/codesign', '--verify', '--strict', str(helper)])
    add('focus-helper', 'ok' if code == 0 else 'fail', 'Exact-window helper signature valid' if code == 0 else 'Exact-window helper missing/invalid: ' + err)
    overview_app = HS_DIR / 'bin/LeanMacOverview.app'
    code, _, err = run(['/usr/bin/codesign', '--verify', '--strict', str(overview_app)])
    overview_ok = code == 0 and os.access(overview_app / 'Contents/MacOS/leanmac-overview', os.X_OK)
    add('overview-helper', 'ok' if overview_ok else 'fail', 'Native AppKit overview signature and executable mode valid' if overview_ok else 'Native overview missing, invalid or not executable: ' + err)
    report['ok'] = not any(c['status'] == 'fail' for c in report['checks'])
    report['warnings'] = sum(c['status'] == 'warn' for c in report['checks'])
    return report


def print_report(report, as_json=False):
    if as_json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(f"Hangar {report['version']} · {report['machine']} · {report.get('profile', '?')}")
        for c in report['checks']:
            print(f"[{c['status'].upper():4}] {c['message']}")


def atomic_bytes(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.leanmac-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save_manifest(backup, manifest):
    atomic_bytes(backup / 'manifest.json', json.dumps(manifest, indent=2).encode())


def snapshot_files(backup, paths):
    (backup / 'files').mkdir(parents=True)
    entries = []
    for index, path in enumerate(paths):
        item = {'path': str(path), 'exists': path.exists() or path.is_symlink(), 'saved': f'files/{index}'}
        if path.is_symlink():
            item['symlink'] = os.readlink(path)
        elif path.exists():
            if not path.is_file():
                raise RuntimeError(f'Expected a file: {path}')
            shutil.copy2(path, backup / item['saved'])
        entries.append(item)
    return entries


def restore_files(backup, entries):
    failures = []
    for item in reversed(entries):
        path = Path(item['path'])
        try:
            if not item['exists']:
                if path.exists() or path.is_symlink():
                    path.unlink()
            elif 'symlink' in item:
                if path.exists() or path.is_symlink():
                    path.unlink()
                path.symlink_to(item['symlink'])
            else:
                saved = backup / item['saved']
                atomic_bytes(path, saved.read_bytes(), saved.stat().st_mode & 0o777)
        except OSError as e:
            failures.append(f'{path}: {e}')
    if failures:
        raise RuntimeError('Restore errors: ' + '; '.join(failures))


def validate_lua(paths):
    lib = ctypes.CDLL(str(HS_APP / 'Contents/Frameworks/LuaSkin.framework/LuaSkin'))
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_close.argtypes = [ctypes.c_void_p]
    for path in paths:
        state = lib.luaL_newstate()
        try:
            if lib.luaL_loadfilex(state, os.fsencode(path), None):
                raise RuntimeError(lib.lua_tolstring(state, -1, None).decode())
        finally:
            lib.lua_close(state)


def validate_config(path):
    config = tomllib.loads(path.read_text())
    for callback in config.get('on-window-detected', []):
        commands = callback.get('run', [])
        commands = [commands] if isinstance(commands, str) else commands
        if any(re.match(r'^\s*eval(?:\s|$)', command) for command in commands):
            raise RuntimeError(f'{path.name}: callback commands already use AeroSpace shell; nested eval is forbidden')
    bindings = config.get('mode', {}).get('main', {}).get('binding', {})
    required = ['alt-' + str(i) for i in range(1, 5)] + ['alt-shift-' + str(i) for i in range(1, 5)] + ['f18', 'f19']
    if any(not bindings.get(key) for key in required):
        raise RuntimeError(f'{path.name}: missing required workspace/MX bindings')
    if 'alt-tab' in bindings or any('leanmac-hotkeys' in str(v) for v in bindings.values()):
        raise RuntimeError(f'{path.name}: conflicting shortcut ownership')
    return config


@contextlib.contextmanager
def install_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'install.lock').open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another Hangar install/rollback is running')
        yield


def new_backup(prefix='install'):
    root = STATE / 'backup'
    root.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=dt.datetime.now().strftime('%Y%m%d-%H%M%S-') + prefix + '-', dir=root))


def reload_previous():
    problems = []
    if CONFIG.exists():
        code, out, err = run([AERO, 'reload-config', '--no-gui'])
        if code:
            problems.append('AeroSpace: ' + (err or out))
    if (HS_DIR / 'init.lua').exists():
        run([HS, '-t', '2', '-c', 'hs.reload()'], timeout=4)
        time.sleep(1)
        code, out, err = run([HS, '-t', '2', '-c', "print('LEANMAC_ROLLBACK_IPC')"], timeout=4)
        if code or 'LEANMAC_ROLLBACK_IPC' not in out:
            problems.append('Hammerspoon reload could not be confirmed: ' + (err or out))
    return problems


def runtime_check():
    state = hs_snapshot()
    required = ('accessibility', 'loaded', 'pickerSubscriber', 'pickerForward', 'pickerBackward',
                'pickerSearch', 'snapKeys', 'snapMouse', 'mxPicker', 'paletteKey', 'healthWatcher', 'groupKeys', 'overviewKey', 'pickerPanel')
    missing = [k for k in required if not state.get(k)]
    if state.get('version') != VERSION:
        missing.append('installed version')
    if not state.get('paletteCommands'):
        missing.append('palette command list')
    if state.get('nativeRouterLoaded'):
        missing.append('native router disabled')
    if missing:
        raise RuntimeError('Runtime health failed: ' + ', '.join(missing))


EXTRA_PREFS = {
    'com.stonerl.Thaw': {'UseIceBar': True, 'UseIceBarOnlyOnNotchedDisplay': False,
        'ShowOnClick': True, 'ShowOnHover': False, 'ShowOnScroll': False, 'AutoRehide': True},
    'cc.ffitch.shottr': {
        'KeyboardShortcuts_fullscreen': '{"carbonKeyCode":18,"carbonModifiers":768}',
        'KeyboardShortcuts_area': '{"carbonKeyCode":21,"carbonModifiers":768}',
        'KeyboardShortcuts_ocr': '{"carbonKeyCode":31,"carbonModifiers":6400}'},
}


def preference_domain(domain):
    code, out, err = run(['/usr/bin/defaults', 'export', domain, '-'])
    if code:
        if 'does not exist' in err.lower() or 'not found' in err.lower():
            return {}
        raise RuntimeError('Cannot back up preferences: ' + (err or out))
    return plistlib.loads(out.encode())


def preference_changes():
    changes = {domain: dict(values) for domain, values in EXTRA_PREFS.items()}
    symbolic = preference_domain('com.apple.symbolichotkeys').get('AppleSymbolicHotKeys', {})
    symbolic['30'] = {'enabled': False, 'value': {'type': 'standard', 'parameters': [52, 21, 1179648]}}
    changes['com.apple.symbolichotkeys'] = {'AppleSymbolicHotKeys': symbolic}
    return changes


def apply_preferences(changes, backup):
    for index, (domain, values) in enumerate(changes.items()):
        merged = preference_domain(domain)
        merged.update(values)
        scratch = backup / f'preferences-apply-{index}.plist'
        atomic_bytes(scratch, plistlib.dumps(merged))
        run(['/usr/bin/defaults', 'import', domain, scratch], required=True)


def restore_extras(backup, manifest):
    for app in manifest.get('agents', {}):
        run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/local.leanmac.{app}'])
    for domain, previous in manifest.get('preferences', {}).items():
        merged = preference_domain(domain)
        for key, value in previous.items():
            if value['exists']:
                merged[key] = value['value']
            else:
                merged.pop(key, None)
        scratch = backup / 'preferences-restore.plist'
        atomic_bytes(scratch, plistlib.dumps(merged))
        run(['/usr/bin/defaults', 'import', domain, scratch], required=True)


def reload_agents(manifest):
    for app, was_loaded in manifest.get('agents', {}).items():
        if was_loaded:
            run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}',
                USER_DIR / f'Library/LaunchAgents/local.leanmac.{app}.plist'], required=True)


def restore_transaction(backup, manifest):
    errors = []
    # A preference failure must never prevent the core shortcut files being restored.
    for action in (lambda: restore_extras(backup, manifest),
                   lambda: restore_files(backup, manifest['files']),
                   lambda: reload_agents(manifest)):
        try:
            action()
        except Exception as e:
            errors.append(str(e))
    if errors:
        raise RuntimeError('; '.join(errors))


def install(kit, check_only=False, extras=False):
    if kit is None:
        raise RuntimeError('No source kit found. Extract a release and pass install --kit /path/to/Hangar')
    kit = kit.resolve()
    user_config = resolve_user_config(kit)
    profile = user_config['profile']
    validate_user_config(user_config)
    candidate = Path(user_config['sources']['aerospace'])
    # Staging does not write locks or state into the user's installation.
    with (contextlib.nullcontext() if check_only else install_lock()), tempfile.TemporaryDirectory(prefix='leanmac-stage-') as temp:
        stage = Path(temp)
        staged = {}
        atomic_bytes(stage / 'hangar-settings.lua', render_runtime_settings(user_config).encode())
        staged[HS_DIR / 'hangar-settings.lua'] = stage / 'hangar-settings.lua'
        for name in LUA_FILES:
            shutil.copy2(kit / 'config' / name, stage / name)
            staged[HS_DIR / name] = stage / name
        if re.search(r'require\s*\(?\s*[\"\']hotkey-router', (stage / 'leanmac.lua').read_text()):
            raise RuntimeError('The experimental native router must stay inactive')
        init = (HS_DIR / 'init.lua').read_text() if (HS_DIR / 'init.lua').exists() else ''
        if not re.search(r'(?m)^\s*leanmac\s*=\s*require\s*\(?\s*[\"\']leanmac[\"\']', init):
            init += '\n-- Hangar utilities\nleanmac = require("leanmac")\n'
        atomic_bytes(stage / 'init.lua', init.encode())
        staged[HS_DIR / 'init.lua'] = stage / 'init.lua'
        shutil.copy2(candidate, stage / 'aerospace.toml')
        staged[CONFIG] = stage / 'aerospace.toml'
        for config_file in (kit / 'config').glob('aerospace*.toml'):
            validate_config(config_file)
        expected = validate_config(stage / 'aerospace.toml')
        validate_lua([stage / name for name in LUA_FILES] + [stage / 'init.lua', stage / 'hangar-settings.lua'])
        helper = stage / 'leanmac-window-focus'
        run(['/usr/bin/xcrun', 'swiftc', '-module-cache-path', stage / 'SwiftModuleCache',
             kit / 'config/leanmac-window-focus.swift', '-O', '-o', helper], timeout=120, required=True)
        run(['/usr/bin/codesign', '--force', '--sign', '-', helper], required=True)
        run(['/usr/bin/codesign', '--verify', '--strict', helper], required=True)
        staged[HS_DIR / 'bin/leanmac-window-focus'] = helper
        overview_app = stage / 'LeanMacOverview.app'
        overview = overview_app / 'Contents/MacOS/leanmac-overview'
        overview.parent.mkdir(parents=True)
        atomic_bytes(overview_app / 'Contents/Info.plist', plistlib.dumps({
            'CFBundleIdentifier': 'local.leanmac.overview', 'CFBundleName': 'Hangar Spaces',
            'CFBundleExecutable': 'leanmac-overview', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': VERSION, 'LSUIElement': True, 'NSHighResolutionCapable': True}))
        run(['/usr/bin/xcrun', 'swiftc', '-module-cache-path', stage / 'SwiftModuleCache',
             kit / 'config/leanmac-overview.swift', '-O', '-o', overview], timeout=120, required=True)
        run([overview, '--self-test'], required=True)
        run(['/usr/bin/codesign', '--force', '--sign', '-', overview_app], required=True)
        run(['/usr/bin/codesign', '--verify', '--strict', overview_app], required=True)
        for asset in overview_app.rglob('*'):
            if asset.is_file():
                staged[HS_DIR / 'bin/LeanMacOverview.app' / asset.relative_to(overview_app)] = asset
        picker_app = stage / 'LeanMacPicker.app'
        picker = picker_app / 'Contents/MacOS/leanmac-picker'
        picker.parent.mkdir(parents=True)
        atomic_bytes(picker_app / 'Contents/Info.plist', plistlib.dumps({
            'CFBundleIdentifier': 'local.leanmac.picker', 'CFBundleName': 'Hangar Windows',
            'CFBundleExecutable': 'leanmac-picker', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': VERSION, 'LSUIElement': True, 'NSHighResolutionCapable': True}))
        run(['/usr/bin/xcrun', 'swiftc', '-module-cache-path', stage / 'SwiftModuleCache',
             kit / 'config/leanmac-picker.swift', '-O', '-o', picker], timeout=120, required=True)
        run([picker, '--self-test'], required=True)
        run(['/usr/bin/codesign', '--force', '--sign', '-', picker_app], required=True)
        run(['/usr/bin/codesign', '--verify', '--strict', picker_app], required=True)
        for asset in picker_app.rglob('*'):
            if asset.is_file():
                staged[HS_DIR / 'bin/LeanMacPicker.app' / asset.relative_to(picker_app)] = asset
        staged[USER_DIR / '.local/bin/hangar'] = kit / 'bin/hangar'
        staged[USER_DIR / '.local/bin/leanmac'] = kit / 'bin/leanmac'
        staged[USER_DIR / '.local/lib/leanmac/leanmac.py'] = kit / 'tools/leanmac.py'
        if extras:
            for app in ('Shottr', 'Thaw'):
                plist = stage / f'local.leanmac.{app}.plist'
                atomic_bytes(plist, plistlib.dumps({'Label': f'local.leanmac.{app}',
                    'ProgramArguments': ['/usr/bin/open', '-gj', '-a', app], 'RunAtLoad': True}))
                staged[USER_DIR / 'Library/LaunchAgents' / plist.name] = plist
        compile((kit / 'tools/leanmac.py').read_text(), 'leanmac.py', 'exec')
        run(['/bin/bash', '-n', kit / 'bin/hangar'], required=True)
        run(['/bin/bash', '-n', kit / 'bin/leanmac'], required=True)
        run(['/bin/bash', '-n', kit / 'install.command'], required=True)
        print(f'Staging passed: {profile}, {len(LUA_FILES) + 2} Lua files, TOML profiles, compiled/signed focus helper.', flush=True)
        if check_only:
            print('No live config replaced. AeroSpace semantic validation runs during guarded activation.')
            return
        native = USER_DIR / 'Library/LaunchAgents/local.leanmac.hotkeys.plist'
        if native.exists() or run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/local.leanmac.hotkeys'])[0] == 0:
            raise RuntimeError('Experimental native helper is installed/running; disable it before installing')
        for old in (STATE / 'backup').glob('*/manifest.json'):
            if json.loads(old.read_text()).get('status') in ('applying', 'rollback-failed'):
                raise RuntimeError(f'Unfinished transaction: {old.parent.name}. Run hangar rollback {old.parent.name}')
        xdg = xdg_config_root() / 'aerospace/aerospace.toml'
        paths = list(staged)
        if xdg.exists() or xdg.is_symlink():
            paths.append(xdg)
        backup = new_backup()
        manifest = {'schema': 1, 'version': VERSION, 'status': 'prepared', 'profile': profile,
                    'files': snapshot_files(backup, paths), 'kit': str(kit),
                    'xdgAerospace': str(xdg) if xdg in paths else None}
        changes = preference_changes() if extras else {}
        manifest['preferences'], manifest['agents'] = {}, {}
        for domain, values in changes.items():
            before = preference_domain(domain)
            manifest['preferences'][domain] = {key: {'exists': key in before, 'value': before.get(key)} for key in values}
        if extras:
            manifest['agents'] = {app: run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/local.leanmac.{app}'])[0] == 0 for app in ('Shottr', 'Thaw')}
        (backup / 'candidate').mkdir()
        for i, (dest, source) in enumerate(staged.items()):
            shutil.copy2(source, backup / 'candidate' / str(i))
        manifest['hashes'] = {str(dest): hashlib.sha256(source.read_bytes()).hexdigest() for dest, source in staged.items()}
        save_manifest(backup, manifest)
        def interrupted(signum, frame):
            raise RuntimeError(f'Installation interrupted by signal {signum}')
        handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            manifest['status'] = 'applying'
            save_manifest(backup, manifest)
            for dest, source in staged.items():
                atomic_bytes(dest, source.read_bytes(), 0o755 if dest.name in ('hangar', 'leanmac', 'leanmac-window-focus', 'leanmac-overview', 'leanmac-picker') else 0o600)
            if xdg in paths:
                xdg.unlink()  # The exact duplicate is retained in the backup.
            # Atomic per file; AeroSpace semantic validation requires its live config path.
            # Auto-reload may observe this replacement. Any failure restores the snapshot.
            if run([AERO, 'list-monitors', '--count'])[0]:
                run(['/usr/bin/open', '-gj', '-a', 'AeroSpace'], required=True)
                time.sleep(2)
            run([AERO, 'reload-config', '--dry-run', '--warnings-as-errors', '--no-gui'], required=True)
            run([AERO, 'reload-config', '--no-gui'], required=True)
            active = json_result(run([AERO, 'config', '--get', 'mode.main.binding', '--json']))
            wanted = expected['mode']['main']['binding']
            if any(active.get(k) != ('; '.join(v) if isinstance(v, list) else v) for k, v in wanted.items()):
                raise RuntimeError('AeroSpace did not load all staged bindings')
            run(['/usr/bin/open', '-gj', '-a', 'Hammerspoon'], required=True)
            run([HS, '-t', '2', '-c', 'hs.reload()'], timeout=4)
            deadline, error = time.monotonic() + 15, None
            while time.monotonic() < deadline:
                time.sleep(1)
                try:
                    runtime_check()
                    error = None
                    break
                except (RuntimeError, ValueError) as e:
                    error = e
            if error:
                raise error
            if changes:
                apply_preferences(changes, backup)
                for app in manifest['agents']:
                    run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/local.leanmac.{app}'])
                    run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}',
                        USER_DIR / f'Library/LaunchAgents/local.leanmac.{app}.plist'], required=True)
            for dest, digest in manifest['hashes'].items():
                if hashlib.sha256(Path(dest).read_bytes()).hexdigest() != digest:
                    raise RuntimeError(f'Installed file changed during verification: {dest}')
            manifest['status'] = 'committed'
            save_manifest(backup, manifest)
            atomic_bytes(STATE / 'last-install', backup.name.encode())
            print(f'Installed and verified. Backup: {backup}\nPalette: {user_config["hotkeys"]["palette"]}\nCheck: hangar doctor', flush=True)
        except BaseException as e:
            manifest['error'] = str(e)
            try:
                restore_transaction(backup, manifest)
                manifest['status'] = 'rolled-back'
            except BaseException as restore_error:
                manifest['status'] = 'rollback-failed'
                manifest['rollbackError'] = str(restore_error)
            manifest['reloadWarnings'] = reload_previous()
            save_manifest(backup, manifest)
            raise RuntimeError(f"Install failed: {e}. Transaction: {manifest['status']}. Backup: {backup}. "
                               + '; '.join(manifest.get('reloadWarnings', []))) from e
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)


def rollback(name):
    if name == 'last':
        name = (STATE / 'last-install').read_text().strip()
    if Path(name).name != name or name in ('.', '..'):
        raise RuntimeError('Use a backup name, not a path')
    backup = STATE / 'backup' / name
    with install_lock():
        manifest = json.loads((backup / 'manifest.json').read_text())
        if manifest.get('schema') != 1:
            raise RuntimeError('This backup predates transactional installs; follow README rollback instructions')
        allowed = {USER_DIR / '.local/bin/hangar'} | {HS_DIR / n for n in LUA_FILES + ('init.lua', 'workspace-overview.html', 'hangar-settings.lua')} | {CONFIG,
            HS_DIR / 'bin/leanmac-window-focus', HS_DIR / 'bin/leanmac-overview',
            HS_DIR / 'bin/LeanMacOverview.app/Contents/Info.plist',
            HS_DIR / 'bin/LeanMacOverview.app/Contents/MacOS/leanmac-overview',
            HS_DIR / 'bin/LeanMacOverview.app/Contents/_CodeSignature/CodeResources', USER_DIR / '.local/bin/leanmac',
            HS_DIR / 'bin/LeanMacPicker.app/Contents/Info.plist',
            HS_DIR / 'bin/LeanMacPicker.app/Contents/MacOS/leanmac-picker',
            HS_DIR / 'bin/LeanMacPicker.app/Contents/_CodeSignature/CodeResources',
            USER_DIR / '.local/lib/leanmac/leanmac.py',
            USER_DIR / 'Library/LaunchAgents/local.leanmac.Shottr.plist',
            USER_DIR / 'Library/LaunchAgents/local.leanmac.Thaw.plist',
            USER_DIR / '.config/aerospace/aerospace.toml'}
        # New backups retain the exact duplicate location across XDG changes.
        # Legacy backups did not record it: accept their saved absolute AeroSpace
        # target with the same narrow filename shape, including external XDG roots.
        duplicates = ([manifest['xdgAerospace']] if manifest.get('xdgAerospace') else
                      [i['path'] for i in manifest['files'] if i['path'].endswith('/aerospace/aerospace.toml')])
        for saved in duplicates:
            target = Path(saved)
            if not target.is_absolute() or '..' in target.parts or target.parts[-2:] != ('aerospace', 'aerospace.toml'):
                raise RuntimeError('Backup contains an invalid XDG AeroSpace target')
            allowed.add(target)
        for item in manifest['files']:
            if Path(item['path']) not in allowed or not re.fullmatch(r'files/\d+', item['saved']):
                raise RuntimeError('Backup contains an unexpected target')
        rescue = new_backup('before-rollback')
        rescue_manifest = {'schema': 1, 'status': 'saved', 'files': snapshot_files(rescue, [Path(i['path']) for i in manifest['files']]),
                           'xdgAerospace': str(duplicates[0]) if duplicates else None}
        rescue_manifest['preferences'], rescue_manifest['agents'] = {}, {}
        for domain, keys in manifest.get('preferences', {}).items():
            before = preference_domain(domain)
            rescue_manifest['preferences'][domain] = {key: {'exists': key in before, 'value': before.get(key)} for key in keys}
        for app in manifest.get('agents', {}):
            rescue_manifest['agents'][app] = run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/local.leanmac.{app}'])[0] == 0
        save_manifest(rescue, rescue_manifest)
        try:
            restore_transaction(backup, manifest)
        finally:
            warnings = reload_previous()
        manifest['status'] = 'rolled-back'
        save_manifest(backup, manifest)
        print(f'Restored {name}. The replaced files are recoverable in {rescue}.')
        if warnings:
            raise RuntimeError('Files restored; runtime needs attention: ' + '; '.join(warnings))


def default_kit():
    adjacent = Path(__file__).resolve().parent.parent
    if (adjacent / 'config').is_dir():
        return adjacent
    try:
        previous = (STATE / 'last-install').read_text().strip()
        return Path(json.loads((STATE / 'backup' / previous / 'manifest.json').read_text())['kit'])
    except (OSError, ValueError, KeyError):
        return None


def main():
    parser = argparse.ArgumentParser(prog='hangar', description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    d = sub.add_parser('doctor', help='Read-only checks; exit 0 healthy, 1 warnings, 2 failures')
    d.add_argument('--json', action='store_true')
    i = sub.add_parser('install', help='Stage, validate, apply and verify the configuration transaction')
    i.add_argument('--kit', type=Path, default=default_kit())
    i.add_argument('--check', action='store_true', help='Stage and compile only; do not replace live configs')
    i.add_argument('--extras', action='store_true', help='Include Shottr/Thaw preferences and login agents')
    r = sub.add_parser('rollback', help='Restore a transactional backup; save current files first')
    r.add_argument('backup', nargs='?', default='last')
    sub.add_parser('backups', help='List transactional backup names and states')
    sub.add_parser('palette', help='Open the command palette')
    c = sub.add_parser('config', help='Manage desired portable configuration; activation is explicit')
    actions = c.add_subparsers(dest='config_command', required=True)
    actions.add_parser('init', help='Create portable defaults without overwriting existing settings')
    for action in ('show', 'check', 'apply'):
        command = actions.add_parser(action)
        command.add_argument('--kit', type=Path, default=default_kit())
        if action == 'show':
            command.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        if args.command == 'config':
            if args.config_command == 'init':
                init_user_config()
            elif args.config_command == 'apply':
                install(args.kit)
            else:
                config = resolve_user_config(args.kit)
                if args.config_command == 'check':
                    check_user_config(config)
                else:
                    config.pop('runtime_hotkeys')
                    print(json.dumps(config, ensure_ascii=False, indent=None if args.json else 2))
            return 0
        if args.command == 'doctor':
            report = doctor()
            print_report(report, args.json)
            return 2 if not report['ok'] else 1 if report['warnings'] else 0
        if args.command == 'install':
            install(args.kit, args.check, args.extras)
        elif args.command == 'rollback':
            rollback(args.backup)
        elif args.command == 'backups':
            for path in sorted((STATE / 'backup').glob('*/manifest.json'), reverse=True):
                data = json.loads(path.read_text())
                print(f"{path.parent.name}  {data.get('status', '?')}")
        elif args.command == 'palette':
            run([HS, '-t', '3', '-c', 'assert(leanmac and leanmac.palette, "Hangar palette not loaded"); leanmac.palette.show()'], required=True)
        return 0
    except (OSError, ValueError, RuntimeError) as e:
        print(f'Hangar: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())

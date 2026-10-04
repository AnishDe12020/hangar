"""Ground Control's validated settings editor; no live activation on save."""
import copy
import hashlib
import json
from pathlib import Path
import re
import time


PROFILE_DETAILS = {
    'default': {
        'title': 'Work, Browser, Social and Media',
        'description': 'Tiled workspaces W (Work), B (Browser), S (Social) and M (Media). '
                       'Work and Browser prefer the main display; Social and Media prefer a secondary display, falling back to main.',
    },
    'numbered-study': {
        'title': 'Work, Study, Social and Misc',
        'description': 'Vertical accordion workspaces 1 (Work), 2 (Study), 3 (Social) and 4 (Misc), with explicit horizontal pairs. '
                       'Work and Study prefer the main display; Social and Misc prefer a secondary display, falling back to main.',
    },
}


def field_provenance(lm, config):
    """Attribute effective editable fields by presence, including equal overrides."""
    result = {'schema': 'default', 'profile': 'legacy' if config['sources']['profile'] == 'legacy-selector' else 'default',
              'shelf_style': 'default'}
    for section in ('apps', 'hotkeys', 'modules'):
        origin = 'legacy' if section == 'apps' and config['legacy_defaults'] else 'default'
        result.update({f'{section}.{key}': origin for key in config[section]})
    for filename, origin in (('settings.toml', 'shared'), ('settings.local.toml', 'local')):
        path = lm.user_config_dir() / filename
        if not path.exists() and not path.is_symlink():
            continue
        for key, value in lm.read_user_settings(path).items():
            if key in ('apps', 'hotkeys', 'modules'):
                result.update({f'{key}.{nested}': origin for nested in value})
            else:
                result[key] = origin
    return result


def revision(lm):
    digest = hashlib.sha256()
    for path in (lm.user_config_dir() / 'settings.toml', lm.user_config_dir() / 'settings.local.toml',
                 lm.user_config_dir() / 'aerospace.toml', lm.STATE / 'aerospace-profile'):
        digest.update(str(path).encode())
        digest.update(str(path.resolve()).encode())
        digest.update(path.read_bytes() if path.exists() else b'<absent>')
    return digest.hexdigest()


def snapshot(lm, kit):
    for _ in range(3):
        token = revision(lm)
        config = lm.resolve_user_config(kit)
        provenance = field_provenance(lm, config)
        if revision(lm) == token:
            break
    else:
        raise RuntimeError('Settings are changing in another application. Try reloading in a moment.')
    config.pop('runtime_hotkeys', None)
    profiles = ['default']
    if kit:
        profiles += sorted(p.stem.removeprefix('aerospace-') for p in (Path(kit) / 'config').glob('aerospace-*.toml')
                           if not p.stem.startswith('aerospace-local'))
    if config['profile'] not in profiles:
        profiles.append(config['profile'])
    override = bool(config['sources']['aerospace'] and Path(config['sources']['aerospace']).parent == lm.user_config_dir())
    details = {name: copy.deepcopy(PROFILE_DETAILS.get(name, {
        'title': 'Custom profile', 'description': 'A custom AeroSpace profile. Review its routes, workspaces and display assignments before applying.',
    })) for name in profiles}
    return {'version': lm.VERSION, 'config': config, 'revision': token, 'profiles': profiles,
            'provenance': provenance, 'profile_details': details,
            'override_description': 'Your aerospace.toml supplies the complete window layout and takes precedence over the selected profile template.' if override else None,
            'defaults': {'hotkeys': lm.DEFAULT_HOTKEYS, 'apps': lm.PORTABLE_APPS, 'modules': lm.DEFAULT_MODULES},
            'directory': str(lm.user_config_dir()), 'kit': str(kit) if kit else None,
            'override': override}


# Export a deliberately small support report. Never sanitize by walking arbitrary
# input: new doctor fields and raw messages remain private unless explicitly added.
DIAGNOSTIC_CHECKS = frozenset({
    'profile', 'config-file', 'config-location', 'aerospace', 'mapping', 'strict-config',
    'active-config', 'bindings', 'binding-mode', 'hammerspoon', 'accessibility', 'loaded',
    'pickerSubscriber', 'pickerForward', 'pickerBackward', 'pickerSearch', 'snapKeys',
    'snapMouse', 'mxPicker', 'paletteKey', 'healthWatcher', 'groupKeys', 'overviewKey',
    'pickerPanel', 'native-router', 'desktops', 'secure-input', 'native-helper', 'alttab',
    'focus-helper', 'overview-helper', 'runtime-version', 'picker-helper', 'shelf-helper', 'settings-helper',
})
DIAGNOSTIC_FLAGS = frozenset({
    'accessibility', 'loaded', 'pickerSubscriber', 'pickerForward', 'pickerBackward',
    'pickerSearch', 'snapKeys', 'snapMouse', 'mxPicker', 'paletteKey', 'healthWatcher',
    'groupKeys', 'overviewKey', 'pickerPanel', 'nativeRouterLoaded',
})


def diagnostics_export(report):
    """Pure allowlist projection; this function never discovers or reads user data."""
    if not isinstance(report, dict):
        raise ValueError('Expected a Hangar diagnostics report')
    result = {'schema': 1, 'kind': 'hangar-diagnostics'}
    version = report.get('version')
    if isinstance(version, str) and re.fullmatch(r'[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{1,9}', version):
        result['version'] = version
    statuses, severity = {}, {'ok': 0, 'warn': 1, 'fail': 2}
    checks = report.get('checks')
    for check in checks if isinstance(checks, list) else []:
        if not isinstance(check, dict):
            continue
        name, status = check.get('name'), check.get('status')
        if isinstance(name, str) and name in DIAGNOSTIC_CHECKS and isinstance(status, str) and status in severity:
            if severity[status] >= severity.get(statuses.get(name), -1):
                statuses[name] = status
    result['checks'] = [{'id': name, 'status': statuses[name]} for name in sorted(statuses)]
    result['counts'] = {status: sum(value == status for value in statuses.values()) for status in severity}
    state = report.get('hammerspoon')
    result['hammerspoon'] = {key: state[key] for key in sorted(DIAGNOSTIC_FLAGS) if type(state.get(key)) is bool} if isinstance(state, dict) else {}
    if type(report.get('secureInput')) is bool:
        result['secureInput'] = report['secureInput']
    return result


def inline_comment(line):
    quote, escaped = None, False
    for i, char in enumerate(line):
        if escaped:
            escaped = False
        elif quote == '"' and char == '\\':
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in ('"', "'"):
            quote = char
        elif char == '#':
            return line[i:].rstrip('\r\n')
    return ''


def render_edits(lm, original, changes):
    """Patch ordinary scalar TOML while preserving untouched lines and comments.

    Advanced dotted-key/inline-table documents are deliberately rejected if a
    requested edit cannot be expressed losslessly. The original stays intact.
    """
    before = lm.parse_user_settings(original)
    expected = copy.deepcopy(before)
    pending = {}
    for key, value in changes.items():
        if key in ('apps', 'hotkeys', 'modules'):
            expected.setdefault(key, {}).update(value)
            pending.update({(key, k): v for k, v in value.items()})
        else:
            expected[key] = value
            pending[('', key)] = value
    lines, section = [], ''
    for line in original.splitlines(keepends=True):
        table = re.fullmatch(r'\s*\[([a-z]+)\]\s*(?:#.*)?[\r\n]*', line)
        if table:
            section = table[1]
        assignment = re.match(r'^(\s*)([a-z_]+)(\s*=\s*)', line)
        identity = (section, assignment[2]) if assignment else None
        if identity in pending:
            value = pending.pop(identity)
            suffix = inline_comment(line)
            line = f'{assignment[1]}{assignment[2]}{assignment[3]}{json.dumps(value, ensure_ascii=False)}'
            line += ('  ' + suffix if suffix else '') + '\n'
        lines.append(line)
    text = ''.join(lines)
    # Root keys must precede the first table.
    root = ''.join(f'{key} = {json.dumps(value, ensure_ascii=False)}\n' for (table, key), value in pending.items() if not table)
    text = root + text
    for table in ('apps', 'hotkeys', 'modules'):
        additions = {key: value for (group, key), value in pending.items() if group == table}
        if not additions:
            continue
        block = ''.join(f'{key} = {json.dumps(value, ensure_ascii=False)}\n' for key, value in additions.items())
        match = re.search(r'(?m)^\s*\[' + table + r'\]\s*(?:#[^\n]*)?\n', text)
        if match:
            text = text[:match.end()] + block + text[match.end():]
        else:
            text = text.rstrip() + f'\n\n[{table}]\n' + block
    try:
        actual = lm.parse_user_settings(text)
    except ValueError as error:
        raise ValueError('This file uses advanced TOML syntax. Edit it in your text editor; nothing was saved.') from error
    if actual != expected:
        raise ValueError('Cannot preserve this TOML document while editing. Nothing was saved.')
    return text


def save(lm, payload, kit):
    if not isinstance(payload, dict) or payload.keys() - {'revision', 'changes', 'scope'}:
        raise ValueError('Expected revision, changes and optional scope')
    changes = payload.get('changes')
    if not isinstance(changes, dict) or not changes or changes.keys() - {'profile', 'shelf_style', 'apps', 'hotkeys', 'modules'}:
        raise ValueError('No supported settings changes supplied')
    # Validate shape and values before constructing any filesystem paths.
    validation = ''
    for key, value in changes.items():
        if key in ('apps', 'hotkeys', 'modules'):
            if not isinstance(value, dict):
                raise ValueError(f'{key} must be an object')
            validation += f'\n[{key}]\n' + ''.join(f'{k} = {json.dumps(v)}\n' for k, v in value.items())
        elif key in ('profile', 'shelf_style'):
            validation = f'{key} = {json.dumps(value)}\n' + validation
    lm.parse_user_settings(validation)
    scope = payload.get('scope', 'local')
    if scope not in ('local', 'shared'):
        raise ValueError('Scope must be local or shared')
    name = 'settings.local.toml' if scope == 'local' else 'settings.toml'
    with lm.install_lock():
        if payload.get('revision') != revision(lm):
            raise RuntimeError('Settings changed since this window opened. Reload before saving.')
        path = lm.user_config_dir() / name
        # Follow an existing dotfiles symlink intentionally; don't replace its link.
        target = path.resolve() if path.is_symlink() else path
        if path.is_symlink() and not target.is_file():
            raise RuntimeError('Settings symlink target is missing; repair it before saving.')
        original = path.read_text() if path.exists() else '# Hangar settings edited in Ground Control.\n'
        current = lm.resolve_user_config(kit)
        edits = copy.deepcopy(changes)
        if current['legacy_defaults']:
            edits['apps'] = {**current['apps'], **edits.get('apps', {})}
        candidate = render_edits(lm, original, edits)
        resolved = lm.resolve_user_config(kit, {name: candidate})
        lm.validate_user_config(resolved)
        # Verify intent was not shadowed by a higher-priority local override.
        for key, value in changes.items():
            if isinstance(value, dict):
                for nested, wanted in value.items():
                    normalized = lm.parse_hotkey(wanted)[0] if key == 'hotkeys' else wanted
                    if resolved[key][nested] != normalized:
                        raise ValueError(f'{key}.{nested} is overridden on this Mac. Edit local settings instead.')
            elif resolved[key] != value:
                raise ValueError(f'{key} is overridden on this Mac. Edit local settings instead.')
        if payload['revision'] != revision(lm):
            raise RuntimeError('Settings changed during validation. Reload before saving.')
        backup = None
        if target.exists():
            backups = lm.STATE / 'settings-backups'
            backups.mkdir(parents=True, exist_ok=True)
            backup = backups / f'{time.time_ns()}-{name}'
            lm.atomic_bytes(backup, target.read_bytes())
        if payload['revision'] != revision(lm):
            raise RuntimeError('Settings changed while preparing the save. Reload before saving.')
        lm.atomic_bytes(target, candidate.encode(), target.stat().st_mode & 0o777 if target.exists() else 0o600)
        return {'status': 'saved', 'path': str(path), 'backup': str(backup) if backup else None,
                'message': 'Saved desired settings. Apply to activate them.', 'snapshot': snapshot(lm, kit)}

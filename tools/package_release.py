#!/usr/bin/env python3
"""Create a source-only candidate ZIP from an explicit allowlist; never publish."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE_FILES = (
    'README.md', 'LICENSE', 'install.command', 'bin/hangar', 'bin/leanmac',
    'tools/leanmac.py', 'tools/hangar_settings.py', 'tools/hangar_catalog.py',
    'docs/installation.md', 'docs/profiles.md', 'docs/shortcuts.md',
    'docs/troubleshooting.md', 'docs/limitations.md', 'docs/development.md', 'docs/utilities.md',
    'skills/hangar-config/SKILL.md', 'skills/hangar-config/agents/openai.yaml',
    'config/aerospace.toml', 'config/aerospace-numbered-study.toml',
    'config/hangar-config.lua', 'config/leanmac.lua', 'config/window-picker.lua', 'config/window-snap.lua',
    'config/spaces-sync.lua', 'config/mx-buttons.lua', 'config/leanmac-runtime.lua',
    'config/leanmac-health.lua', 'config/leanmac-palette.lua', 'config/window-groups.lua',
    'config/window-links.lua', 'config/workspace-overview.lua', 'config/picker-panel.lua',
    'config/leanmac-window-focus.swift', 'config/leanmac-overview.swift', 'config/leanmac-picker.swift',
    'config/hangar-settings.swift', 'config/hangar-shelf.swift', 'config/utility-catalog.json', 'config/Hangar.icns',
)


def package(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    version = re.search(r"^VERSION = '([0-9.]+)'$", (root / 'tools/leanmac.py').read_text(), re.M)
    if not version:
        raise ValueError('Missing release version')
    version = version.group(1)
    name = f'Hangar-{version}-candidate'
    contents = {}
    for relative in RELEASE_FILES:
        source = root / relative
        if source.is_symlink() or not source.resolve().is_relative_to(root):
            raise ValueError(f'Release source must be an ordinary in-repository file: {relative}')
        contents[relative] = source.read_bytes()
    manifest = {'format': 1, 'version': version, 'product': 'Hangar', 'license': 'MIT', 'status': 'candidate',
                'files': {key: hashlib.sha256(data).hexdigest() for key, data in sorted(contents.items())}}
    contents['MANIFEST.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{name}.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as stream:
        for relative, data in sorted(contents.items()):
            entry = zipfile.ZipInfo(f'{name}/{relative}', date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = 0o755 if relative in ('install.command', 'bin/hangar', 'bin/leanmac') else 0o644
            entry.external_attr = (0o100000 | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            stream.writestr(entry, data)
    checksum = output / f'{archive.name}.sha256'
    checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
    return archive, checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    for path in package(ROOT, args.output):
        print(path)


if __name__ == '__main__':
    main()

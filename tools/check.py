#!/usr/bin/env python3
"""Run isolated checks. --native compiles/signs helpers without live activation."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true')
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py'], cwd=ROOT, check=True)
    subprocess.run([sys.executable, 'tests/run_picker_tests.py'], cwd=ROOT, check=True)
    for script in ('install.command', 'bin/hangar', 'bin/leanmac'):
        subprocess.run(['/bin/bash', '-n', script], cwd=ROOT, check=True)
    if args.native:
        spec = importlib.util.spec_from_file_location('leanmac', ROOT / 'tools/leanmac.py')
        lm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lm)
        with tempfile.TemporaryDirectory(prefix='leanmac-check-') as directory:
            lm.USER_DIR = Path(directory)
            lm.STATE = lm.USER_DIR / 'state'
            lm.user_config_dir = lambda: lm.USER_DIR / '.config/hangar'
            lm.CONFIG = lm.USER_DIR / '.aerospace.toml'
            lm.HS_DIR = lm.USER_DIR / '.hammerspoon'
            desired = lm.user_config_dir()
            desired.mkdir(parents=True)
            (desired / 'settings.toml').write_text('schema=1\nprofile="numbered-study"\n[apps]\nterminal="Terminal"\n[hotkeys]\noverview="ctrl-alt-u"\n')
            (desired / 'settings.local.toml').write_text('[apps]\nbrowser="Safari"\n')
            lm.install(ROOT, check_only=True)
            assert not lm.STATE.exists(), 'Staging wrote persistent state'
            assert not lm.CONFIG.exists(), 'Staging activated a configuration'
    return 0


if __name__ == '__main__':
    sys.exit(main())

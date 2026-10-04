"""Utility choices never become arbitrary commands or replace existing apps."""
import importlib.util
import json
import os
import shlex
import time
from unittest.mock import patch
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('hangar_catalog', ROOT / 'tools/hangar_catalog.py')
cat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cat)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.apps = self.root / 'Applications'
        self.apps.mkdir()
        self.calls = []

    def app(self, name='Shottr.app', bundle='cc.ffitch.shottr'):
        target = self.apps / name / 'Contents'
        target.mkdir(parents=True)
        (target / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
        return target.parent

    def runner(self, command, emit):
        self.calls.append(command)
        if command[1] == 'install':
            self.app()
        if emit:
            emit('Downloaded fixture')
        return subprocess.CompletedProcess(command, 0, 'Installed fixture\n')

    def catalog(self, **kwargs):
        options = dict(app_dirs=[self.apps], system='Darwin', macos='26.0',
                       architecture='arm64', brew='/opt/homebrew/bin/brew',
                       lock_path=self.root / 'install.lock', runner=self.runner,
                       brew_prefixes=[self.root.resolve() / 'Homebrew'],
                       launcher_dir=self.root.resolve() / 'Launchers')
        options.update(kwargs)
        return cat.Catalog(**options)

    def mole(self, prefix=None):
        prefix = prefix or self.root.resolve() / 'Homebrew'
        executable = prefix / 'Cellar/mole/1.35.0/bin/mo'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        (prefix / 'bin').mkdir(exist_ok=True)
        (prefix / 'bin/mo').symlink_to(executable)
        return executable

    def test_mole_formula_install_and_known_discovery_preserve_existing_command(self):
        def install(command, emit):
            self.calls.append(command)
            self.mole()
            return subprocess.CompletedProcess(command, 0, '')
        catalog = self.catalog(runner=install)
        result = catalog.install('mole')
        self.assertEqual(result['status'], 'installed')
        self.assertEqual(self.calls, [['/opt/homebrew/bin/brew', 'install', '--formula', 'homebrew/core/mole']])
        self.assertEqual(catalog.install('mole')['status'], 'already_installed')
        self.assertEqual(len(self.calls), 1)
        item = next(x for x in catalog.status() if x['id'] == 'mole')
        self.assertEqual(item['type'], 'cli')
        self.assertEqual(item['package_type'], 'formula')
        self.assertTrue(item['launch_available'])
        self.assertFalse(item['available'])
        self.assertIn('Terminal', item['launch_label'])
        self.assertFalse((self.root / 'Launchers').exists(), 'Listing and installation must not generate scripts')

    def test_unknown_mo_occupant_is_preserved_and_cannot_be_opened(self):
        prefix = self.root.resolve() / 'Homebrew'
        (prefix / 'bin').mkdir(parents=True)
        occupant = prefix / 'bin/mo'
        occupant.write_text('unrelated command')
        occupant.chmod(0o755)
        catalog = self.catalog()
        self.assertEqual(catalog.install('mole')['status'], 'blocked')
        self.assertEqual(catalog.open('mole')['status'], 'not_installed')
        self.assertEqual(occupant.read_text(), 'unrelated command')
        occupant.unlink()
        outside = self.root / 'other-mo'
        outside.write_text('#!/bin/sh\nexit 0\n')
        outside.chmod(0o755)
        occupant.symlink_to(outside)
        self.assertEqual(catalog.install('mole')['status'], 'blocked')
        self.assertEqual(self.calls, [])

    def test_opener_allows_recognized_apps_and_only_fixed_mole_status(self):
        installed = self.app('My Shottr.app')
        catalog = self.catalog()
        self.assertEqual(catalog.open('shottr')['status'], 'opened')
        self.assertEqual(self.calls, [['/usr/bin/open', str(installed)]])
        self.calls.clear()
        for value in ('stats', 'mole clean', '--force', '../mole'):
            self.assertFalse(catalog.open(value)['ok'])
        self.assertEqual(self.calls, [])
        # A path containing shell syntax still becomes one quoted executable argument.
        prefix = self.root.resolve() / "Homebrew's ; quoted"
        executable = self.mole(prefix)
        catalog = self.catalog(brew_prefixes=[prefix])
        result = catalog.open('mole')
        self.assertEqual(result['status'], 'opened')
        script = self.root.resolve() / 'Launchers/Mole Status.command'
        self.assertEqual(self.calls, [['/usr/bin/open', '-a', '/System/Applications/Utilities/Terminal.app', str(script)]])
        self.assertEqual(shlex.split(script.read_text().splitlines()[-1]), ['exec', str(executable), 'status'])
        self.assertEqual(script.stat().st_mode & 0o777, 0o700)
        self.assertTrue(catalog.open('mole')['ok'], 'An owned generated launcher can be refreshed')

    def test_mole_launcher_refuses_unrelated_files_and_symlinked_paths(self):
        self.mole()
        directory = self.root.resolve() / 'Launchers'
        directory.mkdir()
        target = directory / 'Mole Status.command'
        target.write_text('user script')
        catalog = self.catalog()
        self.assertEqual(catalog.open('mole')['status'], 'failed')
        self.assertEqual(target.read_text(), 'user script')
        target.unlink()
        outside = self.root / 'outside'
        outside.write_text('preserve')
        target.symlink_to(outside)
        self.assertEqual(catalog.open('mole')['status'], 'failed')
        self.assertEqual(outside.read_text(), 'preserve')
        target.unlink()
        directory.rmdir()
        directory.symlink_to(self.apps, target_is_directory=True)
        self.assertEqual(catalog.open('mole')['status'], 'failed')
        self.assertFalse((self.apps / 'Mole Status.command').exists())
        self.assertEqual(self.calls, [])

    def test_compatibility_distinguishes_app_support_from_installer_support(self):
        entries = {x['id']: x for x in self.catalog(macos='11.0').status()}
        self.assertFalse(entries['tinycast']['available'])
        self.assertFalse(entries['shottr']['available'])
        self.assertIn('12', entries['shottr']['reason'])
        for values in ({'system': 'Linux'}, {'architecture': 'riscv64'}, {'macos': ''}):
            self.assertTrue(all(not x['available'] for x in self.catalog(**values).status()))
        self.assertTrue(all(x['available'] for x in self.catalog().status()))

    def test_existing_renamed_user_app_is_preserved_without_process(self):
        installed = self.app('My Shottr.app')
        result = self.catalog().install('shottr')
        self.assertEqual(result['status'], 'already_installed')
        self.assertEqual(result['installed_path'], str(installed))
        self.assertEqual(self.calls, [])
        self.assertTrue(installed.exists())

    def test_occupied_destination_is_not_overwritten(self):
        (self.apps / 'Shottr.app').write_text('user data')
        result = self.catalog().install('shottr')
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(self.calls, [])
        self.assertEqual((self.apps / 'Shottr.app').read_text(), 'user data')

    def test_companion_installs_use_core_casks_and_preserve_detected_apps(self):
        fixtures = [('localsend', 'LocalSend.app', 'org.localsend.localsendApp'),
                    ('iina', 'IINA.app', 'com.colliderli.iina'),
                    ('stats', 'Stats.app', 'eu.exelban.Stats')]
        for utility_id, name, bundle in fixtures:
            with self.subTest(utility_id=utility_id):
                calls = []
                def install(command, emit):
                    calls.append(command)
                    self.app(name, bundle)
                    return subprocess.CompletedProcess(command, 0, '')
                catalog = self.catalog(runner=install)
                result = catalog.install(utility_id)
                self.assertEqual(result['status'], 'installed')
                self.assertEqual(calls, [['/opt/homebrew/bin/brew', 'install', '--cask', '--quarantine', 'homebrew/cask/' + utility_id]])
                self.assertEqual(catalog.install(utility_id)['status'], 'already_installed')
                self.assertEqual(len(calls), 1)

    def test_iina_architecture_requirements_and_companion_os_boundaries(self):
        for arch, os_version, utility_id, available in [
            ('arm64', '11.0', 'iina', False), ('x86_64', '11.0', 'iina', True),
            ('arm64', '12.0', 'iina', True), ('x86_64', '10.15', 'localsend', False),
            ('arm64', '11.0', 'localsend', True), ('arm64', '11.9', 'stats', False),
            ('x86_64', '12.0', 'stats', True),
        ]:
            with self.subTest(architecture=arch, macos=os_version, utility_id=utility_id):
                entries = {x['id']: x for x in self.catalog(macos=os_version, architecture=arch).status()}
                self.assertIn(utility_id, entries)
                self.assertEqual(entries[utility_id]['available'], available)
                if not available:
                    self.assertEqual(self.catalog(macos=os_version, architecture=arch).install(utility_id)['status'], 'unsupported')
        self.assertEqual(self.calls, [])

    def test_unknown_ids_cannot_reach_subprocess(self):
        for value in ('--force', 'shottr;touch /tmp/pwned', '../shottr', ''):
            result = self.catalog().install(value, allow_unnotarized=True)
            self.assertEqual(result['status'], 'unknown_utility')
        self.assertEqual(self.calls, [])

    def test_tinycast_requires_explicit_boolean_consent_before_any_mutation(self):
        for consent in (False, 'true', 1, None):
            result = self.catalog().install('tinycast', allow_unnotarized=consent)
            self.assertEqual(result['status'], 'consent_required')
            self.assertIn('quarantine', result['message'])
        self.assertEqual(self.calls, [])
        self.assertFalse((self.root / 'install.lock').exists())

    def test_consented_tinycast_uses_correct_architecture_and_verified_bundle(self):
        def install(command, emit):
            self.calls.append(command)
            if command[1] == 'install':
                self.app('Tinycast.app', 'com.tinycast.app')
            return subprocess.CompletedProcess(command, 0, '')
        result = self.catalog(architecture='x86_64', runner=install).install('tinycast', allow_unnotarized=True)
        self.assertEqual(result['status'], 'installed')
        self.assertEqual(self.calls[0], ['/opt/homebrew/bin/brew', 'trust', '--tap', 'abue-ammar/tinycast'])
        self.assertEqual(self.calls[1], ['/opt/homebrew/bin/brew', 'install', '--cask', '--quarantine', 'abue-ammar/tinycast/tinycast-universal'])

    def test_trust_failure_stops_before_install_and_explains_persistent_change(self):
        def failure(command, emit):
            self.calls.append(command)
            return subprocess.CompletedProcess(command, 1, 'Unknown command: trust')
        result = self.catalog(runner=failure).install('tinycast', allow_unnotarized=True)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(len(self.calls), 1)
        self.assertIn('trust', result['message'])
        self.assertIn('Unknown command', result['output'])
        self.assertIn('trust already applied remains', result['message'])

    def test_homebrew_missing_and_unsupported_platform_do_not_create_lock(self):
        for options, expected in (({'brew': ''}, 'homebrew_required'), ({'system':'Linux'}, 'unsupported')):
            result = self.catalog(**options).install('shottr')
            self.assertEqual(result['status'], expected)
        self.assertFalse((self.root / 'install.lock').exists())
        self.assertEqual(self.calls, [])

    def test_success_streams_progress_and_requires_installed_bundle(self):
        updates = []
        result = self.catalog().install('shottr', emit=updates.append)
        self.assertEqual(result['status'], 'installed')
        self.assertTrue(result['ok'])
        self.assertTrue(any('Downloaded' in line for line in updates))
        self.assertEqual(self.calls, [['/opt/homebrew/bin/brew', 'install', '--cask', '--quarantine', 'homebrew/cask/shottr']])

    def test_false_success_and_process_failures_are_actionable(self):
        def no_app(command, emit):
            return subprocess.CompletedProcess(command, 0, 'All done')
        result = self.catalog(runner=no_app).install('shottr')
        self.assertEqual(result['status'], 'verification_failed')
        self.assertFalse(result['ok'])
        def failure(command, emit):
            return subprocess.CompletedProcess(command, 1, 'Permission denied: /Applications')
        result = self.catalog(runner=failure).install('shottr')
        self.assertEqual(result['status'], 'failed')
        self.assertIn('Permission denied', result['output'])
        def timeout(command, emit):
            raise subprocess.TimeoutExpired(command, 900)
        self.assertEqual(self.catalog(runner=timeout).install('shottr')['status'], 'timed_out')
        def missing(command, emit):
            raise FileNotFoundError('brew disappeared')
        self.assertEqual(self.catalog(runner=missing).install('shottr')['status'], 'failed')

    def test_concurrent_install_is_blocked_before_second_process(self):
        import fcntl
        with (self.root / 'install.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.catalog().install('shottr')['status'], 'busy')
        self.assertEqual(self.calls, [])

    def test_cli_json_is_read_only_and_unknown_id_is_nonzero(self):
        result = subprocess.run([sys.executable, str(ROOT / 'tools/hangar_catalog.py'), 'list', '--json'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = json.loads(result.stdout)
        self.assertTrue(entries)
        self.assertTrue(all('id' in entry and 'available' in entry for entry in entries))
        result = subprocess.run([sys.executable, str(ROOT / 'tools/hangar_catalog.py'), 'install', '--json', 'bogus'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['status'], 'unknown_utility')


class ProcessTests(unittest.TestCase):
    def test_installer_cannot_inherit_quarantine_or_upgrade_overrides(self):
        command = [sys.executable, '-c', "import os,json;print(json.dumps(dict(os.environ)))"]
        with patch.dict(os.environ, {'HOMEBREW_CASK_OPTS': '--no-quarantine --force', 'HOMEBREW_NO_INSTALL_UPGRADE': '0'}):
            result = cat._run_process(command)
        environment = json.loads(result.stdout)
        self.assertNotIn('HOMEBREW_CASK_OPTS', environment)
        self.assertEqual(environment.get('HOMEBREW_NO_INSTALL_UPGRADE'), '1')
        self.assertEqual(environment['HOMEBREW_NO_INSTALL_CLEANUP'], '1')

    def test_streamed_output_is_bounded_and_combines_stderr(self):
        updates = []
        result = cat._run_process([sys.executable, '-c', "import sys;sys.stdout.write('x'*100000);sys.stdout.flush();sys.stderr.write('Final diagnostic\\n')"], updates.append)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 65536)
        self.assertTrue(result.stdout.endswith('Final diagnostic\n'))
        self.assertTrue(updates)
        self.assertLessEqual(max(map(len, updates)), 4096)

    def test_timeout_stops_child_installer_too(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = str(Path(directory) / 'survived')
            child = "import pathlib,time;time.sleep(0.6);pathlib.Path(" + repr(marker) + ").touch()"
            parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c'," + repr(child) + "]);time.sleep(10)"
            with self.assertRaises(subprocess.TimeoutExpired):
                cat._run_process([sys.executable, '-c', parent], timeout=0.15)
            time.sleep(0.8)
            self.assertFalse(Path(marker).exists())


if __name__ == '__main__':
    unittest.main()

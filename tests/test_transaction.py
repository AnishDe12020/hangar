"""Failure injection uses temporary paths and fake services; never the live Mac."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

KIT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('leanmac', KIT / 'tools/leanmac.py')
lm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lm)


class Transactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='leanmac-test-')
        self.root = Path(self.temp.name)
        self.user = self.root / 'user'
        self.user.mkdir()
        self.kit = self.root / 'kit'
        shutil.copytree(KIT, self.kit, ignore=shutil.ignore_patterns('__pycache__', '.git', 'dist', 'work'))
        self.state = self.user / 'Library/Application Support/LeanMac'
        self.hs = self.user / '.hammerspoon'
        self.hs.mkdir()
        self.config = self.user / '.aerospace.toml'
        self.config.write_bytes(b'old config bytes\n')
        self.init = self.hs / 'init.lua'
        self.init.write_text('-- unrelated user customization\nuserSetting = 42\n')
        self.patches = [patch.object(lm, 'USER_DIR', self.user), patch.object(lm, 'STATE', self.state),
            patch.object(lm, 'user_config_dir', lambda: self.user / '.config/hangar'), patch.object(lm, 'CONFIG', self.config), patch.object(lm, 'HS_DIR', self.hs),
            patch.object(lm, 'run', self.fake_run), patch.object(lm, 'runtime_check'),
            patch.object(lm.time, 'sleep'), patch.object(lm, 'reload_previous', return_value=[])]
        for p in self.patches:
            p.start()
        self.fail_on = None

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.temp.cleanup()

    def fake_run(self, args, timeout=5, required=False):
        args = [str(a) for a in args]
        if self.fail_on and self.fail_on in args:
            if required:
                raise RuntimeError('injected ' + self.fail_on)
            return 1, '', 'injected failure'
        if 'swiftc' in args:
            Path(args[args.index('-o') + 1]).write_bytes(b'compiled fixture')
        if args[0] == '/bin/launchctl' and args[1] == 'print':
            return 1, '', 'not loaded'
        if 'config' in args and '--json' in args:
            cfg = lm.tomllib.loads(self.config.read_text())
            bindings = {k: '; '.join(v) if isinstance(v, list) else v for k, v in cfg['mode']['main']['binding'].items()}
            return 0, json.dumps(bindings), ''
        return 0, '', ''

    def manifests(self):
        return [json.loads(p.read_text()) for p in (self.state / 'backup').glob('*/manifest.json')]

    def test_apron_update_waits_for_owned_lock_and_uses_graceful_quit(self):
        lock = self.state / 'Apron/instance.lock'
        lock.parent.mkdir(parents=True)
        with lock.open('w+') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            def quit_helper(args, timeout=5, required=False):
                self.assertEqual([str(a) for a in args], [
                    str(self.hs / 'bin/HangarShelf.app/Contents/MacOS/hangar-shelf'), '--quit'])
                fcntl.flock(owner, fcntl.LOCK_UN)
                return 0, '', ''
            with patch.object(lm, 'run', quit_helper):
                lm.stop_shelf_for_update()
            # Quiescence checking leaves the instance file usable by the next launch.
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_apron_update_noops_when_absent_or_unlocked_and_rejects_unsafe_lock(self):
        lock = self.state / 'Apron/instance.lock'
        with patch.object(lm, 'run', side_effect=AssertionError('must not launch Apron')):
            lm.stop_shelf_for_update()
            lock.parent.mkdir(parents=True)
            lock.write_text('')
            lm.stop_shelf_for_update()
            lock.unlink()
            target = lock.parent / 'unrelated'
            target.write_text('preserve me')
            lock.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, 'Apron'):
                lm.stop_shelf_for_update()
            self.assertEqual(target.read_text(), 'preserve me')
            lock.unlink()
            lock.mkdir()
            with self.assertRaisesRegex(RuntimeError, 'Apron'):
                lm.stop_shelf_for_update()

    def test_busy_apron_prevents_install_and_restore_from_replacing_files(self):
        lock = self.state / 'Apron/instance.lock'
        lock.parent.mkdir(parents=True)
        backup = lm.new_backup('fixture')
        manifest = {'files': lm.snapshot_files(backup, [self.config])}
        with lock.open('w+') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(lm.time, 'monotonic', side_effect=[0, 21]):
                with self.assertRaisesRegex(RuntimeError, 'Apron'):
                    lm.install(self.kit)
            self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
            self.assertFalse((self.hs / 'leanmac.lua').exists())
            self.config.write_text('current config')
            with patch.object(lm.time, 'monotonic', side_effect=[0, 21]):
                with self.assertRaisesRegex(RuntimeError, 'Apron'):
                    lm.restore_transaction(backup, manifest)
            self.assertEqual(self.config.read_text(), 'current config')

    def test_installed_cli_requires_source_instead_of_assuming_icloud(self):
        with patch.object(lm, '__file__', str(self.user / '.local/lib/leanmac/leanmac.py')):
            self.assertIsNone(lm.default_kit())
        with self.assertRaisesRegex(RuntimeError, 'No source kit found'):
            lm.install(None)
        self.assertFalse(self.state.exists())

    def test_check_does_not_create_persistent_state(self):
        lm.install(self.kit, check_only=True)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')

    def test_compile_failure_never_touches_live_files(self):
        self.fail_on = 'swiftc'
        with self.assertRaisesRegex(RuntimeError, 'injected'):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertEqual(self.manifests(), [])

    def test_native_overview_is_executable(self):
        lm.install(self.kit)
        self.assertEqual((self.hs / 'bin/LeanMacOverview.app/Contents/MacOS/leanmac-overview').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.hs / 'bin/LeanMacPicker.app/Contents/MacOS/leanmac-picker').stat().st_mode & 0o777, 0o755)

    def test_invalid_lua_rejected_before_apply(self):
        (self.kit / 'config/leanmac-palette.lua').write_text('local broken = )')
        with self.assertRaises(RuntimeError):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertEqual(self.manifests(), [])

    def test_missing_bindings_rejected_before_apply(self):
        (self.kit / 'config/aerospace.toml').write_text('[mode.main.binding]\n')
        with self.assertRaisesRegex(RuntimeError, 'missing required'):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')

    def test_nested_callback_eval_rejected_before_apply(self):
        path = self.kit / 'config/aerospace-numbered-study.toml'
        path.write_text(path.read_text().replace("'test %{window-parent-container-layout}", "'eval test %{window-parent-container-layout}", 1))
        with self.assertRaisesRegex(RuntimeError, 'nested eval'):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')

    def test_numbered_layout_keys_preserve_groups(self):
        config = lm.validate_config(self.kit / 'config/aerospace-numbered-study.toml')
        keys = config['mode']['main']['binding']
        self.assertEqual(config['default-root-container-orientation'], 'vertical')
        self.assertEqual(keys['alt-slash'], 'layout h_tiles')
        self.assertEqual(keys['alt-shift-slash'], 'layout v_accordion')
        self.assertFalse(any('flatten-workspace-tree' in str(v) for v in keys.values()))
        self.assertEqual(keys['alt-f'], 'fullscreen')

    def test_semantic_failure_restores_files_and_removes_new_files(self):
        self.fail_on = '--dry-run'
        with self.assertRaisesRegex(RuntimeError, 'rolled-back'):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertEqual(self.init.read_text(), '-- unrelated user customization\nuserSetting = 42\n')
        self.assertFalse((self.hs / 'leanmac-health.lua').exists())
        self.assertFalse((self.user / '.local/bin/leanmac').exists())
        self.assertEqual(self.manifests()[0]['status'], 'rolled-back')

    def test_partial_write_failure_restores_every_original(self):
        original = lm.atomic_bytes
        fired = False
        def fail_once(path, data, mode=0o600):
            nonlocal fired
            if Path(path) == self.hs / 'leanmac-palette.lua' and not fired:
                fired = True
                raise OSError('injected disk failure')
            return original(path, data, mode)
        with patch.object(lm, 'atomic_bytes', fail_once):
            with self.assertRaisesRegex(RuntimeError, 'rolled-back'):
                lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertFalse((self.hs / 'leanmac.lua').exists())

    def test_runtime_failure_rolls_back(self):
        with patch.object(lm, 'runtime_check', side_effect=RuntimeError('IPC failed')):
            with patch.object(lm.time, 'monotonic', side_effect=[0, 1, 16]):
                with self.assertRaisesRegex(RuntimeError, 'rolled-back'):
                    lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertFalse((self.hs / 'leanmac.lua').exists())

    def test_preference_restore_failure_still_restores_shortcuts(self):
        self.fail_on = '--dry-run'
        with patch.object(lm, 'restore_extras', side_effect=RuntimeError('preference restore failed')):
            with self.assertRaisesRegex(RuntimeError, 'rollback-failed'):
                lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertFalse((self.hs / 'leanmac.lua').exists())

    def test_commit_idempotence_and_manual_rollback(self):
        lm.install(self.kit)
        self.assertEqual(self.manifests()[0]['status'], 'committed')
        first_backup = (self.state / 'last-install').read_text()
        lm.install(self.kit)
        self.assertEqual(self.init.read_text().count('leanmac = require("leanmac")'), 1)
        self.assertIn('userSetting = 42', self.init.read_text())
        lm.rollback(first_backup)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')
        self.assertFalse((self.user / '.local/bin/leanmac').exists())
        self.assertTrue(any(m['status'] == 'saved' for m in self.manifests()))

    def test_apply_compiles_persistent_settings_and_rollback_leaves_desired_sources(self):
        directory = self.user / '.config/hangar'
        directory.mkdir(parents=True)
        source = directory / 'settings.toml'
        source.write_text('schema = 1\n[apps]\nterminal = "Custom Terminal"\n[hotkeys]\noverview = "ctrl-alt-o"\n')
        before = source.read_bytes()
        lm.install(self.kit)
        generated = self.hs / 'hangar-settings.lua'
        self.assertIn('Custom Terminal', generated.read_text())
        self.assertIn('["mods"]={"ctrl","alt"}', generated.read_text())
        self.assertTrue((self.hs / 'hangar-config.lua').exists())
        lm.rollback('last')
        self.assertFalse(generated.exists())
        self.assertFalse((self.hs / 'hangar-config.lua').exists())
        self.assertEqual(source.read_bytes(), before)

    def test_xdg_duplicate_rollback_survives_environment_change(self):
        # External XDG roots and symlink duplicates are supported without touching
        # the symlink target. Rescue backups must retain the location too.
        duplicate = self.root / 'external-config/aerospace/aerospace.toml'
        duplicate.parent.mkdir(parents=True)
        source = self.root / 'original.toml'
        source.write_text('original duplicate')
        duplicate.symlink_to(source)
        with patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'external-config')}):
            lm.install(self.kit)
        self.assertFalse(duplicate.exists())
        self.assertEqual(source.read_text(), 'original duplicate')
        with patch.dict(os.environ, {'XDG_CONFIG_HOME': ''}):
            self.assertEqual(lm.xdg_config_root(), self.user / '.config')
            lm.rollback('last')
        self.assertTrue(duplicate.is_symlink())
        self.assertEqual(duplicate.read_text(), 'original duplicate')
        rescue = next(p.parent for p in (self.state / 'backup').glob('*/manifest.json')
                      if json.loads(p.read_text()).get('status') == 'saved')
        with patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'different')}):
            lm.rollback(rescue.name)
        self.assertFalse(duplicate.exists())
        self.assertEqual(source.read_text(), 'original duplicate')

    def test_upgrade_reuses_legacy_profile_and_restores_old_cli(self):
        self.state.mkdir(parents=True)
        (self.state / 'aerospace-profile').write_text('numbered-study\n')
        old_cli = self.user / '.local/bin/leanmac'
        old_core = self.user / '.local/lib/leanmac/leanmac.py'
        old_cli.parent.mkdir(parents=True)
        old_core.parent.mkdir(parents=True)
        old_cli.write_text('#!/bin/bash\necho legacy\n')
        old_cli.chmod(0o755)
        old_core.write_text('# legacy core\n')
        self.init.write_text('userSetting = 42\nleanmac = require("leanmac")\n')
        legacy_backup = lm.new_backup('legacy')
        lm.save_manifest(legacy_backup, {'schema': 1, 'status': 'committed',
            'files': lm.snapshot_files(legacy_backup, [self.config, old_cli, old_core])})
        original_manifest = (legacy_backup / 'manifest.json').read_bytes()
        lm.install(self.kit)
        installed_backup = (self.state / 'last-install').read_text()
        self.assertEqual((legacy_backup / 'manifest.json').read_bytes(), original_manifest)
        self.assertEqual(lm.selected_profile(), 'numbered-study')
        self.assertEqual(self.init.read_text().count('require("leanmac")'), 1)
        for command in ['hangar', 'leanmac']:
            binary = self.user / '.local/bin' / command
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            result = subprocess.run([str(binary), '--help'], capture_output=True, text=True, check=True)
            self.assertIn('usage: hangar', result.stdout)
            self.assertIn('Hangar diagnostics', result.stdout)
        lm.rollback(installed_backup)
        self.assertEqual(old_cli.read_text(), '#!/bin/bash\necho legacy\n')
        self.assertEqual(old_core.read_text(), '# legacy core\n')
        self.assertFalse((self.user / '.local/bin/hangar').exists())
        self.assertEqual(lm.selected_profile(), 'numbered-study')
        lm.rollback(legacy_backup.name)  # old schema/targets remain accepted
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')

    def test_legacy_manifest_still_discovers_source_kit(self):
        self.state.mkdir(parents=True)
        backup = lm.new_backup('legacy')
        lm.save_manifest(backup, {'schema': 1, 'kit': str(self.kit)})
        (self.state / 'last-install').write_text(backup.name)
        with patch.object(lm, '__file__', str(self.user / '.local/lib/leanmac/leanmac.py')):
            self.assertEqual(lm.default_kit(), self.kit)

    def test_profile_choice_is_local(self):
        self.state.mkdir(parents=True)
        (self.state / 'aerospace-profile').write_text('numbered-study\n')
        lm.install(self.kit)
        self.assertEqual(lm.tomllib.loads(self.config.read_text())['persistent-workspaces'], ['1', '2', '3', '4'])

    def test_unknown_profile_has_no_fallback(self):
        self.state.mkdir(parents=True)
        (self.state / 'aerospace-profile').write_text('nonexistent\n')
        with self.assertRaisesRegex(RuntimeError, 'does not exist'):
            lm.install(self.kit)
        self.assertEqual(self.config.read_bytes(), b'old config bytes\n')

    def test_duplicate_config_symlink_is_restored(self):
        duplicate = self.user / '.config/aerospace/aerospace.toml'
        duplicate.parent.mkdir(parents=True)
        source = self.user / 'personal-aerospace.toml'
        source.write_text('personal source\n')
        duplicate.symlink_to(source)
        self.fail_on = '--dry-run'
        with self.assertRaisesRegex(RuntimeError, 'rolled-back'):
            lm.install(self.kit)
        self.assertTrue(duplicate.is_symlink())
        self.assertEqual(source.read_text(), 'personal source\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)

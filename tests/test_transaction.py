"""Failure injection uses temporary paths and fake services; never the live Mac."""
import importlib.util
import json
from pathlib import Path
import shutil
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
        shutil.copytree(KIT, self.kit, ignore=shutil.ignore_patterns('__pycache__'))
        self.state = self.user / 'Library/Application Support/LeanMac'
        self.hs = self.user / '.hammerspoon'
        self.hs.mkdir()
        self.config = self.user / '.aerospace.toml'
        self.config.write_bytes(b'old config bytes\n')
        self.init = self.hs / 'init.lua'
        self.init.write_text('-- unrelated user customization\nuserSetting = 42\n')
        self.patches = [patch.object(lm, 'USER_DIR', self.user), patch.object(lm, 'STATE', self.state),
            patch.object(lm, 'CONFIG', self.config), patch.object(lm, 'HS_DIR', self.hs),
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
        self.assertEqual(keys['alt-slash'], 'layout tiles')
        self.assertEqual(keys['alt-shift-slash'], 'layout accordion')
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

"""Real desired-file edits in temporary homes; never activate a desktop."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


lm = module('settings_core', 'leanmac.py')
editor = module('settings_editor', 'hangar_settings.py')


class SettingsEditor(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / 'config'
        self.config.mkdir()
        self.patches = [patch.object(lm, 'STATE', self.root / 'state'), patch.object(lm, 'user_config_dir', lambda: self.config)]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in reversed(self.patches): p.stop()
        self.temp.cleanup()

    def save(self, changes, **extra):
        return editor.save(lm, {'revision': editor.revision(lm), 'changes': changes, **extra}, ROOT)

    def test_first_local_edit_preserves_legacy_launchers_and_is_not_activated(self):
        reply = self.save({'modules': {'shelf': False}})
        config = lm.resolve_user_config(ROOT)
        self.assertEqual(config['apps'], lm.LEGACY_APPS)
        self.assertFalse(config['modules']['shelf'])
        self.assertEqual(reply['status'], 'saved')
        self.assertFalse((self.config / 'settings.toml').exists())
        self.assertFalse((self.root / '.hammerspoon').exists())

    def test_shared_symlink_comments_and_local_overlay_survive(self):
        source = self.root / 'dotfiles.toml'
        source.write_text('# laptop setup\nschema=1\n[apps]\nterminal = "Terminal" # daily terminal\nbrowser = "Safari"\n')
        (self.config / 'settings.toml').symlink_to(source)
        local = self.config / 'settings.local.toml'; local.write_text('[apps]\nbrowser="Firefox"\n')
        result = self.save({'apps': {'terminal': 'Ghostty'}}, scope='shared')
        self.assertTrue((self.config / 'settings.toml').is_symlink())
        self.assertIn('# daily terminal', source.read_text())
        self.assertIn('# laptop setup', source.read_text())
        self.assertEqual(lm.resolve_user_config(ROOT)['apps']['browser'], 'Firefox')
        self.assertEqual(Path(result['backup']).read_text().splitlines()[3], 'terminal = "Terminal" # daily terminal')
        self.assertEqual(local.read_text(), '[apps]\nbrowser="Firefox"\n')

    def test_stale_window_rejects_concurrent_change(self):
        payload = {'revision': editor.revision(lm), 'changes': {'apps': {'terminal': 'Ghostty'}}}
        (self.config / 'settings.toml').write_text('schema=1\n')
        with self.assertRaisesRegex(RuntimeError, 'Reload'):
            editor.save(lm, payload, ROOT)
        self.assertFalse((self.config / 'settings.local.toml').exists())

    def test_conflicting_hotkey_never_writes_desired_file(self):
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.save({'hotkeys': {'shelf': 'alt-1'}})
        self.assertFalse((self.config / 'settings.local.toml').exists())

    def test_shadowed_shared_edit_is_reported(self):
        (self.config / 'settings.local.toml').write_text('[apps]\nterminal="Ghostty"\n')
        with self.assertRaisesRegex(ValueError, 'overridden'):
            self.save({'apps': {'terminal': 'Terminal'}}, scope='shared')
        self.assertFalse((self.config / 'settings.toml').exists())

    def test_advanced_toml_is_preserved_on_rejected_edit(self):
        path = self.config / 'settings.local.toml'
        original = 'apps = { terminal = "Terminal" } # custom layout\n'
        path.write_text(original)
        with self.assertRaises(ValueError):
            self.save({'apps': {'terminal': 'Ghostty'}})
        self.assertEqual(path.read_text(), original)

    def test_invalid_payload_and_missing_symlink_do_not_create_files(self):
        with self.assertRaises(ValueError): self.save({'modules': {'shelf': 'yes'}})
        (self.config / 'settings.local.toml').symlink_to(self.root / 'missing')
        with self.assertRaises(RuntimeError): self.save({'profile': 'default'})
        self.assertFalse((self.root / 'missing').exists())

    def test_new_keys_and_quoted_hash_survive_roundtrip(self):
        path = self.config / 'settings.local.toml'
        path.write_text('[apps]\nterminal = "Name # inside" # comment\n')
        self.save({'apps': {'terminal': 'App "quoted"', 'finder': 'Finder'}, 'hotkeys': {'shelf': 'ctrl-alt-cmd-z'}})
        config = lm.resolve_user_config(ROOT)
        self.assertEqual(config['apps']['terminal'], 'App "quoted"')
        self.assertIn('# comment', path.read_text())
        self.assertEqual(config['hotkeys']['shelf'], 'ctrl-alt-cmd-z')

    def test_snapshot_retries_if_an_editor_changes_settings_mid_read(self):
        path = self.config / 'settings.toml'
        path.write_text('[apps]\nterminal="Terminal"\n')
        original = lm.resolve_user_config
        calls = []
        def race(*args, **kwargs):
            result = original(*args, **kwargs)
            if not calls:
                path.write_text('[apps]\nterminal="Ghostty"\n')
            calls.append(True)
            return result
        with patch.object(lm, 'resolve_user_config', race):
            result = editor.snapshot(lm, ROOT)
        self.assertEqual(result['config']['apps']['terminal'], 'Ghostty')
        self.assertEqual(result['revision'], editor.revision(lm))

    def test_editor_change_during_validation_is_not_overwritten(self):
        path = self.config / 'settings.local.toml'
        path.write_text('[apps]\nterminal="Terminal"\n')
        original = lm.validate_user_config
        edited = '[apps]\nterminal="Another terminal"\n'
        def race(config):
            result = original(config)
            path.write_text(edited)
            return result
        with patch.object(lm, 'validate_user_config', race):
            with self.assertRaisesRegex(RuntimeError, 'during validation'):
                self.save({'apps': {'browser': 'Firefox'}})
        self.assertEqual(path.read_text(), edited)


if __name__ == '__main__': unittest.main()

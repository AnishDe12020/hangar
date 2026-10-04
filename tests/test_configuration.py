"""Portable desired settings are validated without touching an active desktop."""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

KIT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('hangar_config', KIT / 'tools/leanmac.py')
lm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lm)


class Configuration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hangar-settings-test-')
        self.root = Path(self.temp.name)
        self.config = self.root / 'xdg/hangar'
        self.state = self.root / 'state'
        self.patches = [patch.object(lm, 'USER_DIR', self.root), patch.object(lm, 'STATE', self.state),
                        patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'xdg')})]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.temp.cleanup()

    def write(self, text, name='settings.toml'):
        self.config.mkdir(parents=True, exist_ok=True)
        (self.config / name).write_text(text)

    def test_legacy_defaults_survive_until_deliberate_init(self):
        self.state.mkdir()
        (self.state / 'aerospace-profile').write_text('numbered-study\n')
        old = lm.resolve_user_config(KIT)
        self.assertTrue(old['legacy_defaults'])
        self.assertEqual(old['apps']['terminal'], 'Ghostty')
        self.assertEqual(old['apps']['browser'], 'Brave Browser')
        lm.init_user_config()
        new = lm.resolve_user_config(KIT)
        self.assertEqual(new['apps']['terminal'], 'Terminal')
        self.assertEqual(new['apps']['browser'], 'Safari')
        self.assertEqual(new['profile'], 'numbered-study')
        before = (self.config / 'settings.toml').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            lm.init_user_config()
        self.assertEqual((self.config / 'settings.toml').read_bytes(), before)

    def test_merge_local_overlay_and_full_profile_override(self):
        self.write('schema=1\nprofile="default"\n[apps]\nterminal="Ghostty"\n')
        self.write('profile="numbered-study"\n[apps]\nbrowser="Firefox"\n[hotkeys]\npair="shift-alt-u"\n', 'settings.local.toml')
        shutil.copy2(KIT / 'config/aerospace.toml', self.config / 'aerospace.toml')
        result = lm.resolve_user_config(KIT)
        self.assertEqual(result['profile'], 'numbered-study')
        self.assertEqual(result['apps'], {'terminal':'Ghostty', 'browser':'Firefox', 'finder':'Finder'})
        self.assertEqual(result['hotkeys']['pair'], 'alt-shift-u')
        self.assertEqual(result['sources']['aerospace'], str(self.config / 'aerospace.toml'))
        self.assertEqual(result['sources']['profile'], str(self.config / 'settings.local.toml'))
        self.assertEqual(lm.validate_user_config(result)['persistent-workspaces'], ['W', 'B', 'S', 'M'])
        with patch.dict(os.environ, {'XDG_CONFIG_HOME': ''}):
            self.assertEqual(lm.user_config_dir(), self.root / '.config/hangar')

    def test_invalid_settings_and_collisions_fail(self):
        cases = [
            ('schema=true', 'schema'), ('mystery=1', 'unknown'),
            ('[apps]\npassword="bad"', 'apps'), ('[apps]\nterminal=42', 'string'),
            ('[hotkeys]\nunknown="alt-u"', 'hotkeys'),
            ('[hotkeys]\npair="alt-tab"', 'collision'),
            ('[hotkeys]\npair="cmd-ctrl-alt-w"', 'collision'),
            ('[hotkeys]\npair="hyper-u"', 'Unsupported'),
            ('profile="../../outside"', 'profile'),
        ]
        for text, message in cases:
            with self.subTest(text=text):
                self.write(text)
                with self.assertRaisesRegex(ValueError, message):
                    lm.resolve_user_config(KIT)
        self.write('[hotkeys]\npair="alt-1"')
        with self.assertRaisesRegex(ValueError, 'AeroSpace.*conflicts'):
            lm.validate_user_config(lm.resolve_user_config(KIT))
        self.write('schema=1')
        (self.config / 'aerospace.toml').write_text((KIT / 'config/aerospace.toml').read_text() + '\n[mode.custom.binding]\nctrl-alt-cmd-w = "focus left"\n')
        with self.assertRaisesRegex(ValueError, 'custom.*conflicts'):
            lm.validate_user_config(lm.resolve_user_config(KIT))

    def test_aerospace_enter_escape_aliases_collide_with_hammerspoon(self):
        self.write('schema=1')
        for alias in ('enter', 'esc'):
            with self.subTest(alias=alias):
                (self.config / 'aerospace.toml').write_text((KIT / 'config/aerospace.toml').read_text() +
                    f'\n[mode.custom.binding]\nctrl-alt-cmd-{alias} = "focus left"\n')
                with self.assertRaisesRegex(ValueError, 'custom.*conflicts'):
                    lm.validate_user_config(lm.resolve_user_config(KIT))

    def test_invalid_legacy_selector_never_falls_back(self):
        self.state.mkdir()
        (self.state / 'aerospace-profile').write_text('../bad')
        with self.assertRaisesRegex(ValueError, 'Invalid local'):
            lm.resolve_user_config(KIT)

    def test_source_symlink_is_read_but_missing_source_fails(self):
        self.config.mkdir(parents=True)
        shared = self.root / 'shared.toml'
        shared.write_text('[apps]\nterminal="Shared Terminal"\n')
        (self.config / 'settings.toml').symlink_to(shared)
        self.assertEqual(lm.resolve_user_config(KIT)['apps']['terminal'], 'Shared Terminal')
        shared.unlink()
        with self.assertRaises(OSError):
            lm.resolve_user_config(KIT)

    def test_check_is_lightweight_and_never_creates_runtime_state(self):
        self.write('schema=1\n')
        result = lm.resolve_user_config(KIT)
        with patch.object(lm, 'run', side_effect=AssertionError('must not compile or contact apps')):
            lm.check_user_config(result)
        self.assertFalse(self.state.exists())
        self.assertFalse((self.root / '.hammerspoon').exists())
        self.assertFalse((self.root / '.aerospace.toml').exists())

    def test_generated_settings_preserve_quoted_app_names_without_code(self):
        self.write('[apps]\nterminal=\'App "quoted" \\ name\'\n')
        result = lm.resolve_user_config(KIT)
        generated = lm.render_runtime_settings(result)
        self.assertIn('App \\"quoted\\" \\\\ name', generated)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'generated.lua'
            source.write_text(generated)
            lm.validate_lua([source])

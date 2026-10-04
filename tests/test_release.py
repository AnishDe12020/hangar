"""Verify package integrity and exclusion of local state without touching the Mac."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packager', ROOT / 'tools/package_release.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class Release(unittest.TestCase):
    def test_manifest_complete_and_private_files_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            for relative in packager.RELEASE_FILES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            for relative in ['config/aerospace-local.toml', 'config/window-picker.lua.bak', 'STATUS.md', '.DS_Store']:
                (root / relative).write_text('PRIVATE FIXTURE: must not ship')
            archive, checksum = packager.package(root, Path(directory) / 'dist')
            self.assertTrue(checksum.read_text().startswith(hashlib.sha256(archive.read_bytes()).hexdigest()))
            original = archive.read_bytes()
            packager.package(root, archive.parent)
            self.assertEqual(original, archive.read_bytes(), 'Same source must give the same archive')
            with zipfile.ZipFile(archive) as z:
                prefix = archive.stem + '/'
                manifest = json.loads(z.read(prefix + 'MANIFEST.json'))
                names = {n.removeprefix(prefix) for n in z.namelist()}
                self.assertEqual(names, set(packager.RELEASE_FILES) | {'MANIFEST.json'})
                for relative, expected in manifest['files'].items():
                    self.assertEqual(hashlib.sha256(z.read(prefix + relative)).hexdigest(), expected)
                    self.assertNotIn(b'PRIVATE FIXTURE', z.read(prefix + relative))
                for relative in ['bin/hangar', 'bin/leanmac', 'install.command']:
                    self.assertEqual((z.getinfo(prefix + relative).external_attr >> 16) & 0o777, 0o755)
                self.assertEqual(manifest['product'], 'Hangar')
                self.assertEqual(manifest['license'], 'MIT')
                self.assertIn(b'Copyright (c) 2026 Anish De', z.read(prefix + 'LICENSE'))
                self.assertNotIn('LICENSE-DECISION.md', names)
                self.assertIn('config/leanmac-picker.swift', names)
                self.assertNotIn('config/leanmac-hotkeys.swift', names)
                extracted = Path(directory) / 'extracted'
                z.extractall(extracted)
                for command in ['hangar', 'leanmac']:
                    result = subprocess.run(['/bin/bash', str(extracted / archive.stem / 'bin' / command), '--help'], capture_output=True, text=True, check=True)
                    self.assertIn('usage: hangar', result.stdout)

    def test_runtime_dependencies_are_packaged(self):
        import ast
        module = ast.parse((ROOT / 'tools/leanmac.py').read_text())
        lua_files = next(ast.literal_eval(node.value) for node in module.body
                         if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'LUA_FILES' for t in node.targets))
        for name in lua_files:
            self.assertIn('config/' + name, packager.RELEASE_FILES)

    def test_allowlisted_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tools').mkdir()
            (root / 'tools/leanmac.py').write_text("VERSION = '1.0'\n")
            (root / 'README.md').symlink_to(ROOT / 'README.md')
            with self.assertRaisesRegex(ValueError, 'ordinary in-repository'):
                packager.package(root, root / 'dist')

"""Entrypoint tests substitute a CLI, so dependencies and services cannot run."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]


class Entrypoint(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='leanmac-entry-')
        self.kit = Path(self.temp.name) / 'release with spaces'
        (self.kit / 'bin').mkdir(parents=True)
        shutil.copy2(KIT / 'install.command', self.kit / 'install.command')
        (self.kit / 'bin/leanmac').write_text('#!/bin/bash\nprintf "ARG:%s\\n" "$@"\n')

    def tearDown(self):
        self.temp.cleanup()

    def run_entry(self, *args):
        return subprocess.run(['/bin/bash', str(self.kit / 'install.command'), *args],
                              capture_output=True, text=True, timeout=5)

    def test_help_exits_before_dependency_checks(self):
        result = self.run_entry('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage:', result.stdout)
        self.assertNotIn('ARG:', result.stdout)

    def test_check_routes_straight_to_staging(self):
        result = self.run_entry('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['ARG:install', 'ARG:--kit',
                          'ARG:' + str(self.kit), 'ARG:--check'])

    def test_flags_work_in_either_order(self):
        for args in [('--check', '--configs-only'), ('--configs-only', '--check')]:
            result = self.run_entry(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('ARG:--check', result.stdout)
            self.assertNotIn('ARG:--configs-only', result.stdout)

    def test_unknown_flag_fails_before_dependency_changes(self):
        result = self.run_entry('--misspelled')
        self.assertEqual(result.returncode, 2)
        self.assertIn('Unknown option', result.stderr)

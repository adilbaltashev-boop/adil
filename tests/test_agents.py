"""Подключает тесты каждого агента (agents/*/tests) к общему прогону из корня репозитория."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_tests(loader, standard_tests, pattern):
    suite = unittest.TestSuite()
    for tests_dir in sorted(ROOT.glob("agents/*/tests")):
        suite.addTests(loader.discover(str(tests_dir), pattern="test_*.py", top_level_dir=str(tests_dir)))
    return suite

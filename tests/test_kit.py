import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agent-template" / "evals"))
sys.path.insert(0, str(ROOT / ".claude" / "hooks"))

import block_env  # noqa: E402
import run_evals  # noqa: E402


class BlockEnvHook(unittest.TestCase):
    def blocked(self, **tool_input):
        return block_env.check({"tool_input": tool_input}) is not None

    def test_blocks_secrets(self):
        self.assertTrue(self.blocked(file_path="/proj/.env"))
        self.assertTrue(self.blocked(file_path="/proj/.env.production"))
        self.assertTrue(self.blocked(file_path="/proj/secrets/key.pem"))
        self.assertTrue(self.blocked(command="cat .env"))
        self.assertTrue(self.blocked(command="grep TOKEN .env | head"))

    def test_allows_normal_files(self):
        self.assertFalse(self.blocked(file_path="/proj/.env.example"))
        self.assertFalse(self.blocked(file_path="/proj/app/environment.py"))
        self.assertFalse(self.blocked(command="python -m unittest"))

    def test_exit_code_2_when_blocked(self):
        hook = ROOT / ".claude" / "hooks" / "block_env.py"
        r = subprocess.run([sys.executable, str(hook)], input=json.dumps({"tool_input": {"file_path": ".env"}}),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("запрещён", r.stderr)


class Evals(unittest.TestCase):
    def test_template_cases_are_valid(self):
        cases = run_evals.load_cases(ROOT / "agent-template" / "evals" / "cases.jsonl")
        self.assertTrue(all("id" in c and "input" in c for c in cases))

    def test_checks(self):
        reply = {"text": "Передаю администратору", "tool_calls": [{"name": "handoff_to_human", "args": {}}]}
        self.assertEqual(run_evals.check({"tool": "handoff_to_human"}, reply), [])
        self.assertTrue(run_evals.check({"no_tool": ["handoff_to_human"]}, reply))
        self.assertTrue(run_evals.check({"not_contains": ["администратор"]}, reply))
        self.assertTrue(run_evals.check({"min_len": 1}, {"text": ""}))

    def test_crashing_agent_fails_case_not_run(self):
        def boom(_):
            raise RuntimeError("API down")
        passed, failures = run_evals.run_cases(boom, [{"id": "a", "input": "x"}])
        self.assertEqual(passed, 0)
        self.assertIn("агент упал", failures[0][1][0])


if __name__ == "__main__":
    unittest.main()

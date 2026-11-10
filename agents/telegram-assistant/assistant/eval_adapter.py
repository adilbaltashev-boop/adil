"""Адаптер для agent-template/evals/run_evals.py: решение помощника → формат прогона.

handoff и ignore отдаются как вызовы «инструментов», чтобы в cases.jsonl можно было писать
{"expect": {"tool": "handoff_to_human"}} или {"expect": {"tool": "ignore"}}.
Вход примера может быть строкой или {"text": ..., "where": "comment|dm", "context": ...}.

  python ../../agent-template/evals/run_evals.py evals/cases.jsonl --agent assistant.eval_adapter:run
(запускать из папки agents/telegram-assistant; тратит деньги на API)
"""
from __future__ import annotations

import asyncio
import json

from .brain import Brain

_brain: Brain | None = None


def run(case_input) -> dict:
    global _brain
    _brain = _brain or Brain()
    if isinstance(case_input, str) and case_input.startswith("{"):
        case_input = json.loads(case_input)
    if isinstance(case_input, dict):
        text, where, context = case_input["text"], case_input.get("where", "comment"), case_input.get("context", "")
    else:
        text, where, context = case_input, "comment", ""
    d = asyncio.run(_brain.decide(text, where, context))
    calls = [] if d.action == "reply" else [{"name": "handoff_to_human" if d.action == "handoff" else "ignore",
                                             "args": {"reason": d.reason}}]
    return {"text": d.text, "tool_calls": calls, "reason": d.reason}

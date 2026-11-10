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


async def _decide(text: str, where: str, context: str):
    # Новый клиент на каждый пример: asyncio.run создаёт свой event loop, а пул соединений к нему привязан.
    return await Brain().decide(text, where, context)


def run(case_input) -> dict:
    if isinstance(case_input, str) and case_input.startswith("{"):
        case_input = json.loads(case_input)
    if isinstance(case_input, dict):
        text, where, context = case_input["text"], case_input.get("where", "comment"), case_input.get("context", "")
    else:
        text, where, context = case_input, "comment", ""
    d = asyncio.run(_decide(text, where, context))
    calls = [] if d.action == "reply" else [{"name": "handoff_to_human" if d.action == "handoff" else "ignore",
                                             "args": {"reason": d.reason}}]
    return {"text": d.text, "tool_calls": calls, "reason": d.reason}

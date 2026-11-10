"""Прогон агента на тестовых примерах (evals).

Агент — любая функция `run(text: str) -> dict` вида
    {"text": "ответ клиенту", "tool_calls": [{"name": "...", "args": {...}}]}
Подключается как --agent package.module:function.

Проверки в поле "expect" каждого примера (все необязательные):
    tool          — инструмент, который должен быть вызван
    no_tool       — список инструментов, которые вызывать нельзя
    contains      — подстроки, которые должны быть в ответе
    not_contains  — подстроки, которых быть не должно
    min_len       — минимальная длина ответа

Выход: процент пройденных, список провалов, трейс в evals/results/<время>.jsonl.
Код выхода 1, если результат ниже --threshold.
"""
from __future__ import annotations

import argparse
import importlib
import json
import sys
import time
from pathlib import Path
from typing import Callable

Agent = Callable[[str], dict]


def load_cases(path: Path) -> list[dict]:
    cases = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip():
            try:
                cases.append(json.loads(line))
            except json.JSONDecodeError as e:
                raise SystemExit(f"{path}:{n}: битый JSON: {e}")
    return cases


def check(expect: dict, reply: dict) -> list[str]:
    text = reply.get("text") or ""
    called = [c.get("name") for c in reply.get("tool_calls") or []]
    problems = []
    if "tool" in expect and expect["tool"] not in called:
        problems.append(f"не вызван {expect['tool']} (вызваны: {called or 'ничего'})")
    for name in expect.get("no_tool", []):
        if name in called:
            problems.append(f"вызван запрещённый {name}")
    for s in expect.get("contains", []):
        if s.lower() not in text.lower():
            problems.append(f"в ответе нет «{s}»")
    for s in expect.get("not_contains", []):
        if s.lower() in text.lower():
            problems.append(f"в ответе есть запрещённое «{s}»")
    if len(text) < expect.get("min_len", 0):
        problems.append("ответ пустой или слишком короткий")
    return problems


def run_cases(agent: Agent, cases: list[dict], log_path: Path | None = None) -> tuple[int, list[tuple[str, list[str]]]]:
    passed, failures = 0, []
    log = log_path.open("w", encoding="utf-8") if log_path else None
    try:
        for case in cases:
            started = time.monotonic()
            try:
                reply = agent(case["input"])
                problems = check(case.get("expect", {}), reply)
            except Exception as e:  # падение агента = провал примера, а не всего прогона
                reply, problems = {"error": repr(e)}, [f"агент упал: {e!r}"]
            if problems:
                failures.append((case["id"], problems))
            else:
                passed += 1
            if log:
                log.write(json.dumps({"id": case["id"], "input": case["input"], "reply": reply,
                                      "problems": problems, "seconds": round(time.monotonic() - started, 3)},
                                     ensure_ascii=False) + "\n")
    finally:
        if log:
            log.close()
    return passed, failures


def load_agent(spec: str) -> Agent:
    module, _, func = spec.partition(":")
    if "" not in sys.path and str(Path.cwd()) not in sys.path:
        sys.path.insert(0, str(Path.cwd()))  # агент импортируется из папки, откуда запущен прогон
    return getattr(importlib.import_module(module), func or "run")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("cases", type=Path)
    p.add_argument("--agent", required=True, help="module:function")
    p.add_argument("--threshold", type=float, default=0.9)
    args = p.parse_args(argv)

    cases = load_cases(args.cases)
    if not cases:
        print("Нет примеров. Без набора примеров нет агента — есть демо.")
        return 1
    if len(cases) < 30:
        print(f"Внимание: примеров {len(cases)}, нужно 30+.")
    results = args.cases.parent / "results"
    results.mkdir(exist_ok=True)
    log_path = results / f"{time.strftime('%Y%m%d-%H%M%S')}.jsonl"

    passed, failures = run_cases(load_agent(args.agent), cases, log_path)
    for case_id, problems in failures:
        print(f"✗ {case_id}: " + "; ".join(problems))
    score = passed / len(cases)
    print(f"\n{passed}/{len(cases)} = {score:.0%} (порог {args.threshold:.0%}). Трейс: {log_path}")
    return 0 if score >= args.threshold else 1


if __name__ == "__main__":
    sys.exit(main())

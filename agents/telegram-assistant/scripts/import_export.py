"""Экспорт Telegram Desktop (result.json) → тестовые примеры + примеры стиля владельца.

Берёт пары «чужое сообщение → ответ владельца на него (reply)».
  python scripts/import_export.py path/to/result.json --owner-id 123456789

Пишет:
  evals/cases_from_export.jsonl — пары: вход + эталонный ответ владельца (для прогона)
  data/style_examples.md     — первые N пар, идут в промпт как образец стиля
Файлы содержат переписку людей: в git их не коммитим (см. .gitignore).
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def plain_text(value) -> str:
    """В экспорте text — строка или список из строк и {'type':..., 'text':...}."""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return "".join(p if isinstance(p, str) else p.get("text", "") for p in value).strip()
    return ""


def extract_pairs(export: dict, owner_id: int, min_len: int = 3) -> list[dict]:
    owner = f"user{owner_id}"
    messages = [m for m in export.get("messages", []) if m.get("type") == "message"]
    by_id = {m["id"]: m for m in messages}
    pairs = []
    for m in messages:
        if m.get("from_id") != owner or "reply_to_message_id" not in m:
            continue
        question = by_id.get(m["reply_to_message_id"])
        if not question or question.get("from_id") == owner:
            continue
        q, a = plain_text(question.get("text")), plain_text(m.get("text"))
        if len(q) >= min_len and len(a) >= min_len:
            pairs.append({"id": f"tg-{question['id']}", "input": q, "reference": a})
    return pairs


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("export", type=Path)
    p.add_argument("--owner-id", type=int, required=True, help="твой Telegram user id (узнать: @userinfobot)")
    p.add_argument("--style-examples", type=int, default=15)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args(argv)

    pairs = extract_pairs(json.loads(args.export.read_text(encoding="utf-8")), args.owner_id)
    if not pairs:
        print("Не нашёл ни одного твоего ответа (reply) на чужое сообщение. Проверь --owner-id и что экспорт из группы обсуждения.")
        return 1

    # Стиль и тесты не должны пересекаться: иначе прогон проверяет память, а не умение.
    random.Random(args.seed).shuffle(pairs)
    style, cases = pairs[:args.style_examples], pairs[args.style_examples:]

    (ROOT / "data").mkdir(exist_ok=True)
    (ROOT / "data" / "style_examples.md").write_text(
        "\n\n".join(f"Человек: {s['input']}\nВладелец: {s['reference']}" for s in style), encoding="utf-8")
    with (ROOT / "evals" / "cases_from_export.jsonl").open("w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps({**c, "expect": {"min_len": 1}}, ensure_ascii=False) + "\n")

    print(f"Пар найдено: {len(pairs)}. В стиль: {len(style)}. В тесты: {len(cases)}.")
    if len(cases) < 30:
        print("Тестов меньше 30 — добавь примеры вручную в evals/cases_from_export.jsonl (вопрос + правильный ответ).")
    print("Дальше: проставь в evals/cases_from_export.jsonl ожидания (expect) — где нужен handoff, где ignore, что обязано быть в ответе.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

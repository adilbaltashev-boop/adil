"""Мозг помощника: один вызов модели → решение (ответить / передать владельцу / пропустить).

Это workflow, а не агент с циклом: шаги всегда одинаковые, инструменты не нужны.
Решение модель возвращает строго по JSON-схеме (structured outputs).
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

import anthropic

ROOT = Path(__file__).resolve().parent.parent
MODEL = os.environ.get("ASSISTANT_MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("ASSISTANT_EFFORT", "low")  # чат: low обычно хватает; поднимать только по замерам

DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["reply", "handoff", "ignore"]},
        "text": {"type": "string", "description": "Ответ человеку. Пусто, если action != reply."},
        "reason": {"type": "string", "description": "Коротко, почему такое решение — для владельца."},
    },
    "required": ["action", "text", "reason"],
    "additionalProperties": False,
}


@dataclass
class Decision:
    action: str  # reply | handoff | ignore
    text: str
    reason: str
    input_tokens: int = 0
    output_tokens: int = 0


def _read(name: str) -> str:
    path = ROOT / name
    return path.read_text(encoding="utf-8") if path.exists() else ""


def build_system() -> str:
    """Стабильная часть промпта (кэшируется): инструкция + знания + примеры стиля владельца."""
    parts = [_read("prompt.md")]
    if knowledge := _read("knowledge.md"):
        parts.append(f"<знания>\n{knowledge}\n</знания>")
    if style := _read("data/style_examples.md"):
        parts.append(f"<как_отвечает_владелец>\n{style}\n</как_отвечает_владелец>")
    return "\n\n".join(parts)


def build_user_message(text: str, where: str, context: str = "") -> str:
    """Чужой текст заворачиваем в теги: это данные, а не команды (защита от prompt injection)."""
    where_ru = {"comment": "комментарий под постом канала", "dm": "личное сообщение владельцу"}[where]
    parts = [f"Где: {where_ru}."]
    if context:
        parts.append(f"<контекст>\n{context}\n</контекст>")
    parts.append(f"<сообщение>\n{text}\n</сообщение>")
    return "\n".join(parts)


def parse_decision(response) -> Decision:
    usage = getattr(response, "usage", None)
    tokens = dict(input_tokens=getattr(usage, "input_tokens", 0) or 0,
                  output_tokens=getattr(usage, "output_tokens", 0) or 0)
    if response.stop_reason == "refusal":
        return Decision("handoff", "", "модель отказалась отвечать — посмотри сам", **tokens)
    if response.stop_reason == "max_tokens":
        return Decision("handoff", "", "ответ модели обрезан — посмотри сам", **tokens)
    raw = next((b.text for b in response.content if b.type == "text"), "")
    try:
        data = json.loads(raw)
        action = data["action"] if data.get("action") in ("reply", "handoff", "ignore") else "handoff"
        text = (data.get("text") or "").strip()
        if action == "reply" and not text:
            action = "handoff"
        return Decision(action, text, data.get("reason", ""), **tokens)
    except (json.JSONDecodeError, TypeError):
        return Decision("handoff", "", "не удалось разобрать ответ модели", **tokens)


class Brain:
    def __init__(self, client: anthropic.AsyncAnthropic | None = None):
        self.client = client or anthropic.AsyncAnthropic()
        self.system = build_system()

    async def decide(self, text: str, where: str, context: str = "") -> Decision:
        if not text.strip():
            return Decision("ignore", "", "пустое сообщение (стикер/медиа без подписи)")
        response = await self.client.beta.messages.create(
            model=MODEL,
            max_tokens=2000,
            # Если модель откажет по политике безопасности, API сам повторит запрос на запасной модели.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            output_config={"effort": EFFORT, "format": {"type": "json_schema", "schema": DECISION_SCHEMA}},
            system=[{"type": "text", "text": self.system, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": build_user_message(text, where, context)}],
        )
        return parse_decision(response)

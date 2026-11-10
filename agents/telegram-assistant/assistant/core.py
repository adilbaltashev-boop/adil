"""Логика помощника без Telegram: входящее сообщение → решение → черновик владельцу → отправка.

Telegram-часть (bot.py) только переводит апдейты в вызовы этих методов, поэтому
всю логику можно тестировать без сети.
"""
from __future__ import annotations

import logging
import time
from typing import Protocol

from .brain import Brain
from .store import Draft, Store

log = logging.getLogger("assistant")


class Sender(Protocol):
    async def reply(self, draft: Draft, text: str) -> None: ...
    async def to_owner(self, text: str, draft_id: int | None = None) -> None: ...


def label(text: str, ai_label: str) -> str:
    return f"{text}\n\n— {ai_label}" if ai_label else text


def preview(draft_id: int, source: str, author: str | None, incoming: str, decision_text: str, reason: str) -> str:
    where = "Комментарий" if source == "comment" else "Личка"
    return (f"{where} от {author or 'неизвестно'}:\n«{incoming[:800]}»\n\n"
            f"Черновик #{draft_id}:\n{decision_text}\n\n({reason[:200]})")


class Assistant:
    def __init__(self, brain: Brain, store: Store, sender: Sender, *, auto_reply: bool = False,
                 ai_label: str = "ИИ-помощник", per_chat_hourly_limit: int = 5):
        self.brain, self.store, self.sender = brain, store, sender
        self.auto_reply, self.ai_label = auto_reply, ai_label
        self.per_chat_hourly_limit = per_chat_hourly_limit

    async def _notify(self, text: str, draft_id: int | None = None) -> bool:
        """Сообщение владельцу. Сбой (владелец не нажал /start, сеть) не должен ронять обработку."""
        try:
            await self.sender.to_owner(text, draft_id)
            return True
        except Exception:
            log.exception("notify owner failed")
            return False

    async def on_incoming(self, *, source: str, chat_id: int, message_id: int, text: str, context: str = "",
                          author: str | None = None, business_connection_id: str | None = None) -> int | None:
        if self.store.exists(source, chat_id, message_id):  # повтор апдейта после перезапуска
            return None
        base = dict(source=source, chat_id=chat_id, message_id=message_id, input=text, context=context,
                    author=author, business_connection_id=business_connection_id)

        # Лимит на чат: защита от флуда и бесконечной переписки с другим ботом (и от счёта за API)
        if self.store.recent_count(source, chat_id, 3600) >= self.per_chat_hourly_limit:
            log.warning("rate limit: %s %s", source, chat_id)
            return self.store.add(**base, action="ignore", status="ignored", reason="лимит сообщений в час на чат")

        started = time.monotonic()
        try:
            d = await self.brain.decide(text, source, context)
        except Exception as e:  # сбой API не должен ронять бота: владелец увидит сообщение сам
            log.exception("brain failed")
            draft_id = self.store.add(**base, action="handoff", status="handoff", reason=f"ошибка модели: {e!r}"[:500])
            if draft_id:
                await self._notify(f"⚠️ Не смог подготовить ответ (#{draft_id}), ответь сам:\n«{text[:800]}»")
            return draft_id

        status = {"ignore": "ignored", "handoff": "handoff"}.get(d.action, "auto" if self.auto_reply else "pending")
        draft_id = self.store.add(**base, action=d.action, draft_text=d.text, reason=d.reason, status=status,
                                  input_tokens=d.input_tokens, output_tokens=d.output_tokens,
                                  seconds=round(time.monotonic() - started, 2))
        if draft_id is None:
            return None
        log.info("draft #%s %s/%s: %s", draft_id, source, d.action, d.reason)

        if d.action == "handoff":
            await self._notify(f"🙋 Нужен ты (#{draft_id}) — {d.reason[:200]}\n"
                               f"{'Комментарий' if source == 'comment' else 'Личка'} от {author or '?'}:\n"
                               f"«{text[:800]}»")
        elif d.action == "reply" and self.auto_reply:
            await self._send(self.store.get(draft_id), d.text)
        elif d.action == "reply":
            if not await self._notify(preview(draft_id, source, author, text, d.text, d.reason), draft_id=draft_id):
                self.store.set_failed(draft_id, "не удалось прислать черновик владельцу")
        return draft_id

    async def _send(self, draft: Draft, text: str) -> bool:
        try:
            await self.sender.reply(draft, label(text, self.ai_label))
            return True
        except Exception as e:
            log.exception("send failed")
            self.store.set_failed(draft.id, repr(e))
            await self._notify(f"⚠️ Не удалось отправить #{draft.id}: {e}")
            return False

    def _clear_edit_if(self, draft_id: int) -> None:
        if self.store.editing() == draft_id:
            self.store.set_editing(None)

    # Кнопки владельца
    async def approve(self, draft_id: int) -> str:
        self._clear_edit_if(draft_id)
        draft = self.store.get(draft_id)
        if not draft or draft.status != "pending":
            return "Уже обработано."
        if self.store.resolve(draft_id, "sent", draft.draft_text) and await self._send(draft, draft.draft_text):
            return "Отправлено ✅"
        return "Не отправлено."

    async def skip(self, draft_id: int) -> str:
        self._clear_edit_if(draft_id)
        return "Пропущено." if self.store.resolve(draft_id, "skipped") else "Уже обработано."

    def start_edit(self, draft_id: int) -> str:
        draft = self.store.get(draft_id)
        if not draft or draft.status != "pending":
            return "Уже обработано."
        self.store.set_editing(draft_id)
        return f"Пришли исправленный текст для #{draft_id} следующим сообщением. /cancel — отмена."

    async def owner_text(self, text: str) -> str | None:
        """Текст владельца в личке боту. Если ждём исправление — отправляем его вместо черновика."""
        draft_id = self.store.editing()
        if draft_id is None:
            return None
        self.store.set_editing(None)
        draft = self.store.get(draft_id)
        if not draft or not self.store.resolve(draft_id, "edited", text):
            return "Уже обработано."
        if await self._send(draft, text):
            return "Отправлено с правкой ✅ (сохранил как пример для обучения)"
        return "Не отправлено."

    def cancel_edit(self) -> str:
        self.store.set_editing(None)
        return "Ок, правка отменена. Черновик ждёт решения."

    def report(self, days: int = 7) -> str:
        s = self.store.stats(time.time() - days * 86400)
        decided = s["sent"] + s["edited"] + s["skipped"]
        accuracy = f"{s['sent'] / decided:.0%}" if decided else "—"
        return (f"За {days} дн.:\n"
                f"• отправлено без правок: {s['sent']}\n• с правкой: {s['edited']}\n• отклонено: {s['skipped']}\n"
                f"• передано тебе: {s['handoff']}\n• пропущено (спам/эмодзи/лимит): {s['ignored']}\n"
                f"• ждут решения: {s['pending']}\n• ошибки отправки: {s['failed']}\n"
                f"• автоответов: {s['auto']}\n\n"
                f"Точность черновиков (отправлено без правок): {accuracy}. Порог для автономии — 90%.\n"
                f"Токены: вход {s['input_tokens']:,}, выход {s['output_tokens']:,}.")

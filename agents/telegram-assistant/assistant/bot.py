"""Telegram-обвязка: комментарии в группе обсуждения канала + личка через Telegram Business.

Запуск: python -m assistant.bot  (переменные окружения — см. .env.example)
"""
from __future__ import annotations

import asyncio
import logging
import os

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command
from aiogram.types import (CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message,
                           ReplyParameters)

from .brain import Brain
from .core import Assistant
from .store import Draft, Store


def env_int(name: str) -> int:
    value = os.environ.get(name, "").strip()
    if not value.lstrip("-").isdigit():
        raise SystemExit(f"Не задана переменная {name} (число). См. .env.example")
    return int(value)


def keyboard(draft_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Отправить", callback_data=f"ok:{draft_id}"),
        InlineKeyboardButton(text="✏️ Исправить", callback_data=f"edit:{draft_id}"),
        InlineKeyboardButton(text="✖️ Пропустить", callback_data=f"skip:{draft_id}"),
    ]])


class TelegramSender:
    def __init__(self, bot: Bot, owner_id: int):
        self.bot, self.owner_id = bot, owner_id

    async def reply(self, draft: Draft, text: str) -> None:
        await self.bot.send_message(
            draft.chat_id, text,
            business_connection_id=draft.business_connection_id if draft.source == "dm" else None,
            reply_parameters=ReplyParameters(message_id=draft.message_id, allow_sending_without_reply=True))

    async def to_owner(self, text: str, draft_id: int | None = None) -> None:
        await self.bot.send_message(self.owner_id, text, reply_markup=keyboard(draft_id) if draft_id else None)


def author_of(message: Message) -> str:
    u = message.from_user
    if not u:
        return "?"
    return f"@{u.username}" if u.username else u.full_name


def build_router(assistant: Assistant, owner_id: int, discussion_chat_id: int) -> Router:
    router = Router()

    # 1. Комментарии под постами канала (бот — админ группы обсуждения)
    @router.message(F.chat.id == discussion_chat_id)
    async def on_comment(message: Message) -> None:
        if message.is_automatic_forward or message.sender_chat:  # сам пост канала / ответ от имени канала
            return
        if not message.from_user or message.from_user.is_bot or message.from_user.id == owner_id:
            return
        if not message.reply_to_message:  # не комментарий к посту, а просто сообщение в группе
            return
        parent = message.reply_to_message
        await assistant.on_incoming(
            source="comment", chat_id=message.chat.id, message_id=message.message_id,
            text=message.text or message.caption or "", context=(parent.text or parent.caption or "")[:3000],
            author=author_of(message))

    # 2. Личные сообщения владельцу (Telegram Business → Чат-боты → этот бот)
    @router.business_message()
    async def on_dm(message: Message) -> None:
        if not message.from_user or message.from_user.id == owner_id:  # исходящие владельца тоже приходят сюда
            return
        await assistant.on_incoming(
            source="dm", chat_id=message.chat.id, message_id=message.message_id,
            text=message.text or message.caption or "", author=author_of(message),
            business_connection_id=message.business_connection_id)

    # 3. Владелец ↔ бот: кнопки, правки, отчёт
    @router.callback_query(F.data.regexp(r"^(ok|edit|skip):\d+$"))
    async def on_button(call: CallbackQuery) -> None:
        if call.from_user.id != owner_id:
            await call.answer("Только для владельца.", show_alert=True)
            return
        action, draft_id = call.data.split(":")
        draft_id = int(draft_id)
        if action == "ok":
            result = await assistant.approve(draft_id)
        elif action == "skip":
            result = await assistant.skip(draft_id)
        else:
            result = assistant.start_edit(draft_id)
        await call.answer(result[:200])
        if action != "edit" and call.message:
            await call.message.edit_reply_markup(reply_markup=None)
            await call.message.answer(f"#{draft_id}: {result}")
        elif call.message:
            await call.message.answer(result)

    owner_chat = F.chat.type == "private"

    @router.message(owner_chat, F.from_user.id == owner_id, Command("stats"))
    async def on_stats(message: Message) -> None:
        await message.answer(assistant.report())

    @router.message(owner_chat, F.from_user.id == owner_id, Command("cancel"))
    async def on_cancel(message: Message) -> None:
        await message.answer(assistant.cancel_edit())

    @router.message(owner_chat, F.from_user.id == owner_id, Command("start"))
    async def on_start(message: Message) -> None:
        await message.answer("Я на месте. Черновики ответов буду присылать сюда. /stats — отчёт за неделю.")

    @router.message(owner_chat, F.from_user.id == owner_id, F.text)
    async def on_owner_text(message: Message) -> None:
        result = await assistant.owner_text(message.text)
        await message.answer(result or "Сейчас не жду правку. Нажми «✏️ Исправить» под черновиком.")

    return router


def load_env_file(path: str = ".env") -> None:
    """Простейший загрузчик KEY=VALUE, без зависимостей. Переменные окружения важнее файла."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip())


async def main() -> None:
    load_env_file()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
    if not token:
        raise SystemExit("Не задан TELEGRAM_BOT_TOKEN. См. .env.example")
    owner_id = env_int("OWNER_ID")
    discussion_chat_id = env_int("DISCUSSION_CHAT_ID")

    bot = Bot(token)
    store = Store(os.environ.get("DB_PATH", "data/assistant.db"))
    assistant = Assistant(Brain(), store, TelegramSender(bot, owner_id),
                          auto_reply=os.environ.get("AUTO_REPLY", "false").lower() == "true",
                          ai_label=os.environ.get("AI_LABEL", "ИИ-помощник"))
    dp = Dispatcher()
    dp.include_router(build_router(assistant, owner_id, discussion_chat_id))
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())

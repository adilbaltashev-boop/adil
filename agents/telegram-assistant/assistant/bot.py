"""Telegram-обвязка: комментарии в группе обсуждения канала + личка через Telegram Business.

Запуск: python -m assistant.bot  (из папки agents/telegram-assistant; настройки — env.example)
"""
from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from aiogram import Bot, Dispatcher, F, Router
from aiogram.exceptions import TelegramAPIError, TelegramBadRequest
from aiogram.filters import Command
from aiogram.types import (BusinessConnection, CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message,
                           ReplyParameters)

from .brain import Brain
from .core import Assistant
from .store import Draft, Store

ROOT = Path(__file__).resolve().parent.parent
TG_LIMIT = 4096
log = logging.getLogger("assistant.bot")


def env_int(name: str) -> int:
    value = os.environ.get(name, "").strip()
    if not value.lstrip("-").isdigit():
        raise SystemExit(f"Не задана переменная {name} (число). См. env.example")
    return int(value)


def fit(text: str) -> str:
    return text if len(text) <= TG_LIMIT else text[:TG_LIMIT - 1] + "…"


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
            draft.chat_id, fit(text),
            business_connection_id=draft.business_connection_id if draft.source == "dm" else None,
            reply_parameters=ReplyParameters(message_id=draft.message_id, allow_sending_without_reply=True))

    async def to_owner(self, text: str, draft_id: int | None = None) -> None:
        await self.bot.send_message(self.owner_id, fit(text), reply_markup=keyboard(draft_id) if draft_id else None)


class OwnerConnections:
    """Пускаем в работу только Business-подключения аккаунта владельца.

    Иначе любой пользователь Premium подключит бота к себе, и его переписка уйдёт в модель и владельцу.
    """

    def __init__(self, bot: Bot, owner_id: int):
        self.bot, self.owner_id, self.cache = bot, owner_id, {}

    def remember(self, connection: BusinessConnection) -> None:
        self.cache[connection.id] = connection.user.id == self.owner_id and connection.is_enabled

    async def is_owner(self, connection_id: str | None) -> bool:
        if not connection_id:
            return False
        if connection_id not in self.cache:
            try:
                self.remember(await self.bot.get_business_connection(connection_id))
            except TelegramAPIError:
                log.exception("get_business_connection failed")
                return False
        return self.cache[connection_id]


def author_of(message: Message) -> str:
    u = message.from_user
    if not u:
        return "?"
    return f"@{u.username}" if u.username else u.full_name


def is_comment_for_bot(message: Message, owner_id: int) -> bool:
    """Отвечаем только на комментарий к посту или на ответ самому боту.

    Ответы людей друг другу и ответы владельцу — не наше дело: там разговор ведёт владелец.
    """
    parent = message.reply_to_message
    if not parent:
        return False
    if parent.is_automatic_forward:
        return True
    return bool(parent.from_user and parent.from_user.id == message.bot.id)


def build_router(assistant: Assistant, owner_id: int, discussion_chat_id: int,
                 connections: OwnerConnections | None = None) -> Router:
    router = Router()

    # 1. Комментарии под постами канала (бот — админ группы обсуждения)
    @router.message(F.chat.id == discussion_chat_id)
    async def on_comment(message: Message) -> None:
        if message.is_automatic_forward or message.sender_chat:  # сам пост канала / ответ от имени канала
            return
        if not message.from_user or message.from_user.is_bot or message.from_user.id == owner_id:
            return
        if not is_comment_for_bot(message, owner_id):
            return
        parent = message.reply_to_message
        await assistant.on_incoming(
            source="comment", chat_id=message.chat.id, message_id=message.message_id,
            text=message.text or message.caption or "", context=(parent.text or parent.caption or "")[:3000],
            author=author_of(message))

    # 2. Личные сообщения владельцу (Telegram Business → Чат-боты → этот бот)
    @router.business_connection()
    async def on_connection(connection: BusinessConnection) -> None:
        if connections:
            connections.remember(connection)
        if connection.user.id != owner_id:
            log.warning("чужое Business-подключение от %s — игнорирую", connection.user.id)

    @router.business_message()
    async def on_dm(message: Message) -> None:
        if not message.from_user or message.from_user.id == owner_id:  # исходящие владельца тоже приходят сюда
            return
        if message.from_user.is_bot or message.sender_business_bot:  # другой бот → риск бесконечной переписки
            return
        if connections is None or not await connections.is_owner(message.business_connection_id):
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
        if not isinstance(call.message, Message):  # старое сообщение (>48 ч) — править его нельзя
            await call.bot.send_message(owner_id, f"#{draft_id}: {result}")
            return
        if action != "edit":
            try:
                await call.message.edit_reply_markup(reply_markup=None)
            except TelegramBadRequest:
                pass  # кнопки уже убраны (двойное нажатие)
            await call.message.answer(f"#{draft_id}: {result}")
        else:
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
        if message.text.startswith("/"):  # неизвестная команда не должна уйти клиенту как правка
            await message.answer("Не знаю такую команду. Есть /stats и /cancel.")
            return
        result = await assistant.owner_text(message.text)
        await message.answer(result or "Сейчас не жду правку. Нажми «✏️ Исправить» под черновиком.")

    return router


def load_env_file(path: Path = ROOT / ".env") -> None:
    """Простейший загрузчик KEY=VALUE, без зависимостей. Переменные окружения важнее файла."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


async def main() -> None:
    load_env_file()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
    if not token:
        raise SystemExit("Не задан TELEGRAM_BOT_TOKEN. См. env.example")
    owner_id = env_int("OWNER_ID")
    discussion_chat_id = env_int("DISCUSSION_CHAT_ID")

    bot = Bot(token)
    db_path = Path(os.environ.get("DB_PATH", "data/assistant.db"))
    store = Store(db_path if db_path.is_absolute() else ROOT / db_path)  # всегда внутри папки агента (в .gitignore)
    assistant = Assistant(Brain(), store, TelegramSender(bot, owner_id),
                          auto_reply=os.environ.get("AUTO_REPLY", "false").lower() == "true",
                          ai_label=os.environ.get("AI_LABEL", "ИИ-помощник"),
                          per_chat_hourly_limit=int(os.environ.get("PER_CHAT_HOURLY_LIMIT", "5")))
    dp = Dispatcher()
    dp.include_router(build_router(assistant, owner_id, discussion_chat_id, OwnerConnections(bot, owner_id)))
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())

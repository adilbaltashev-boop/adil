"""SQLite: черновики, решения владельца и лог каждого шага (трейс + метрики)."""
from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS drafts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at REAL NOT NULL,
    source TEXT NOT NULL,                 -- comment | dm
    chat_id INTEGER NOT NULL,
    message_id INTEGER NOT NULL,
    business_connection_id TEXT,
    author TEXT,
    input TEXT NOT NULL,
    context TEXT,
    action TEXT NOT NULL,                 -- решение модели: reply | handoff | ignore
    draft_text TEXT,
    reason TEXT,
    status TEXT NOT NULL,                 -- pending | sent | edited | skipped | handoff | ignored | auto | failed
    final_text TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    seconds REAL DEFAULT 0,
    decided_at REAL,
    UNIQUE (source, chat_id, message_id)   -- повтор апдейта после перезапуска не создаст второй ответ
);
CREATE TABLE IF NOT EXISTS owner_state (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

STATUSES = ("pending", "sent", "edited", "skipped", "handoff", "ignored", "auto", "failed")


@dataclass
class Draft:
    id: int
    source: str
    chat_id: int
    message_id: int
    business_connection_id: str | None
    author: str | None
    input: str
    context: str | None
    action: str
    draft_text: str | None
    reason: str | None
    status: str
    final_text: str | None


class Store:
    def __init__(self, path: str | Path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path))
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def add(self, *, source, chat_id, message_id, input, action, status, business_connection_id=None,
            author=None, context=None, draft_text=None, reason=None, input_tokens=0, output_tokens=0,
            seconds=0.0) -> int | None:
        """None — такое сообщение уже обрабатывали."""
        cur = self.db.execute(
            "INSERT OR IGNORE INTO drafts (created_at, source, chat_id, message_id, business_connection_id, author, input,"
            " context, action, draft_text, reason, status, input_tokens, output_tokens, seconds)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (time.time(), source, chat_id, message_id, business_connection_id, author, input, context, action,
             draft_text, reason, status, input_tokens, output_tokens, seconds))
        self.db.commit()
        return cur.lastrowid if cur.rowcount == 1 else None

    def exists(self, source: str, chat_id: int, message_id: int) -> bool:
        return self.db.execute("SELECT 1 FROM drafts WHERE source = ? AND chat_id = ? AND message_id = ?",
                               (source, chat_id, message_id)).fetchone() is not None

    def recent_count(self, source: str, chat_id: int, seconds: float) -> int:
        return self.db.execute("SELECT COUNT(*) FROM drafts WHERE source = ? AND chat_id = ? AND created_at >= ?",
                               (source, chat_id, time.time() - seconds)).fetchone()[0]

    def get(self, draft_id: int) -> Draft | None:
        row = self.db.execute(
            "SELECT id, source, chat_id, message_id, business_connection_id, author, input, context, action,"
            " draft_text, reason, status, final_text FROM drafts WHERE id = ?", (draft_id,)).fetchone()
        return Draft(**dict(row)) if row else None

    def resolve(self, draft_id: int, status: str, final_text: str | None = None) -> bool:
        """Меняет статус только у ожидающего черновика — защита от двойного нажатия кнопки."""
        assert status in STATUSES
        cur = self.db.execute(
            "UPDATE drafts SET status = ?, final_text = ?, decided_at = ? WHERE id = ? AND status = 'pending'",
            (status, final_text, time.time(), draft_id))
        self.db.commit()
        return cur.rowcount == 1

    def set_failed(self, draft_id: int, error: str) -> None:
        self.db.execute("UPDATE drafts SET status = 'failed', reason = ? WHERE id = ?", (error[:500], draft_id))
        self.db.commit()

    # Ожидание исправленного текста от владельца
    def set_editing(self, draft_id: int | None) -> None:
        if draft_id is None:
            self.db.execute("DELETE FROM owner_state WHERE key = 'editing'")
        else:
            self.db.execute("INSERT OR REPLACE INTO owner_state (key, value) VALUES ('editing', ?)", (str(draft_id),))
        self.db.commit()

    def editing(self) -> int | None:
        row = self.db.execute("SELECT value FROM owner_state WHERE key = 'editing'").fetchone()
        return int(row["value"]) if row else None

    def stats(self, since: float) -> dict:
        rows = self.db.execute(
            "SELECT status, COUNT(*) AS n, SUM(input_tokens) AS inp, SUM(output_tokens) AS out"
            " FROM drafts WHERE created_at >= ? GROUP BY status", (since,)).fetchall()
        result = {s: 0 for s in STATUSES}
        result["input_tokens"] = result["output_tokens"] = 0
        for r in rows:
            result[r["status"]] = r["n"]
            result["input_tokens"] += r["inp"] or 0
            result["output_tokens"] += r["out"] or 0
        return result

    def corrections(self) -> list[sqlite3.Row]:
        """Пары «черновик → как исправил владелец»: готовые новые тестовые примеры."""
        return self.db.execute(
            "SELECT input, context, draft_text, final_text FROM drafts WHERE status = 'edited'").fetchall()

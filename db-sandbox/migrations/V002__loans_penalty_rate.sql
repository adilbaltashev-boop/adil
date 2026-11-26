-- V002. Новое поле: ставка пени по кредиту.
-- Безопасная миграция: обратно совместима, старый код про колонку не знает и не ломается.
SET search_path TO credit;

-- PostgreSQL 11+: ADD COLUMN с константным DEFAULT выполняется мгновенно — таблица не перезаписывается.
ALTER TABLE loans ADD COLUMN penalty_rate numeric(5,2) NOT NULL DEFAULT 0.50;
COMMENT ON COLUMN loans.penalty_rate IS 'Пеня за день просрочки, % от суммы просроченного платежа';

-- CHECK на большой таблице: сначала NOT VALID (без проверки старых строк, блокировка короткая),
-- потом VALIDATE (проверяет старые строки, не блокируя запись).
ALTER TABLE loans ADD CONSTRAINT ck_loans_penalty_rate CHECK (penalty_rate BETWEEN 0 AND 1) NOT VALID;
ALTER TABLE loans VALIDATE CONSTRAINT ck_loans_penalty_rate;

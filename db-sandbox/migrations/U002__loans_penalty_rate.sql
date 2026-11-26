-- Откат V002. Данные колонки теряются — перед откатом на проде их выгружают.
SET search_path TO credit;
ALTER TABLE loans DROP CONSTRAINT IF EXISTS ck_loans_penalty_rate;
ALTER TABLE loans DROP COLUMN IF EXISTS penalty_rate;

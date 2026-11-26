-- V004. Шаг 2 из 2 — CONTRACT (сужение). Накатывается ТОЛЬКО когда старой версии приложения
-- больше нет нигде: ни на серверах, ни в мобильных клиентах, которые ещё не обновились.
SET search_path TO credit;

-- Проверка перед сужением: не осталось строк без кода
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM loan_applications WHERE purpose_code IS NULL) THEN
        RAISE EXCEPTION 'Есть заявки без purpose_code — сужение невозможно';
    END IF;
END $$;

-- SET NOT NULL сканирует всю таблицу под эксклюзивной блокировкой. На большой таблице безопаснее так:
-- CHECK … NOT VALID (мгновенно) → VALIDATE (без блокировки записи) → SET NOT NULL (PG12+ использует проверенный CHECK и не сканирует).
ALTER TABLE loan_applications ADD CONSTRAINT ck_purpose_code_nn CHECK (purpose_code IS NOT NULL) NOT VALID;
ALTER TABLE loan_applications VALIDATE CONSTRAINT ck_purpose_code_nn;
ALTER TABLE loan_applications ALTER COLUMN purpose_code SET NOT NULL;
ALTER TABLE loan_applications DROP CONSTRAINT ck_purpose_code_nn;
DROP TRIGGER sync_purpose ON loan_applications;
DROP FUNCTION trg_sync_purpose();
ALTER TABLE loan_applications DROP COLUMN purpose;     -- необратимо без справочника!

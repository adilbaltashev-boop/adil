-- Откат V003. Безопасен: колонка purpose всё это время заполнялась.
SET search_path TO credit;
DROP TRIGGER IF EXISTS sync_purpose ON loan_applications;
DROP FUNCTION IF EXISTS trg_sync_purpose();
ALTER TABLE loan_applications DROP COLUMN IF EXISTS purpose_code;
DROP TABLE IF EXISTS loan_purposes;

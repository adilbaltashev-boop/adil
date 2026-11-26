-- Откат V004: возвращаем текстовую колонку, восстанавливая значения из справочника.
-- Возможен только потому, что справочник однозначно отображает код в текст.
SET search_path TO credit;

ALTER TABLE loan_applications ADD COLUMN purpose text;
UPDATE loan_applications a SET purpose = p.name FROM loan_purposes p WHERE p.code = a.purpose_code;
ALTER TABLE loan_applications ALTER COLUMN purpose SET NOT NULL;
ALTER TABLE loan_applications ALTER COLUMN purpose_code DROP NOT NULL;

CREATE FUNCTION trg_sync_purpose() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.purpose_code IS NULL AND NEW.purpose IS NOT NULL THEN
        SELECT code INTO NEW.purpose_code FROM loan_purposes WHERE name = NEW.purpose;
    ELSIF NEW.purpose IS NULL AND NEW.purpose_code IS NOT NULL THEN
        SELECT name INTO NEW.purpose FROM loan_purposes WHERE code = NEW.purpose_code;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER sync_purpose
BEFORE INSERT OR UPDATE OF purpose, purpose_code ON loan_applications
FOR EACH ROW EXECUTE FUNCTION trg_sync_purpose();

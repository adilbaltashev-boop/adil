-- V003. Цель кредита: свободный текст → код из справочника. Шаг 1 из 2 — EXPAND (расширение).
-- Старая версия приложения продолжает писать только purpose (текст),
-- новая — только purpose_code. Триггер заполняет второе поле, пока живы обе версии.
SET search_path TO credit;

CREATE TABLE loan_purposes (
    code text PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE loan_purposes IS 'Справочник целей кредита';

INSERT INTO loan_purposes (code, name) VALUES
    ('HOME_REPAIR',       'Ремонт жилья'),
    ('HOUSEHOLD_GOODS',   'Покупка техники'),
    ('MEDICAL',           'Лечение'),
    ('EDUCATION',         'Обучение'),
    ('REFINANCING',       'Рефинансирование займов'),
    ('WORKING_CAPITAL',   'Пополнение оборотных средств'),
    ('EQUIPMENT',         'Покупка оборудования'),
    ('RETAIL_RENT',       'Аренда торговой точки'),
    ('LIVESTOCK',         'Покупка скота'),
    ('SOWING',            'Посевная кампания'),
    ('FARM_MACHINERY',    'Покупка техники для хозяйства'),
    ('BEAUTY_SALON',      'Открытие салона красоты'),
    ('TAILORING',         'Пошив одежды');

-- Новая колонка без NOT NULL: старые строки и старое приложение её не заполняют
ALTER TABLE loan_applications ADD COLUMN purpose_code text REFERENCES loan_purposes (code);

-- Перенос данных. На проде — пачками по 5–10 тыс. строк, чтобы не держать долгие блокировки.
UPDATE loan_applications a
SET purpose_code = p.code
FROM loan_purposes p
WHERE p.name = a.purpose AND a.purpose_code IS NULL;

CREATE INDEX ix_applications_purpose_code ON loan_applications (purpose_code);

-- Обратная совместимость на время перехода
CREATE FUNCTION trg_sync_purpose() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- при изменении одного поля пересчитываем второе, иначе они разъедутся
        IF NEW.purpose IS DISTINCT FROM OLD.purpose AND NEW.purpose_code IS NOT DISTINCT FROM OLD.purpose_code THEN
            SELECT code INTO NEW.purpose_code FROM loan_purposes WHERE name = NEW.purpose;
        ELSIF NEW.purpose_code IS DISTINCT FROM OLD.purpose_code AND NEW.purpose IS NOT DISTINCT FROM OLD.purpose THEN
            SELECT name INTO NEW.purpose FROM loan_purposes WHERE code = NEW.purpose_code;
        END IF;
    ELSIF NEW.purpose_code IS NULL AND NEW.purpose IS NOT NULL THEN     -- INSERT от старой версии
        SELECT code INTO NEW.purpose_code FROM loan_purposes WHERE name = NEW.purpose;
    ELSIF NEW.purpose IS NULL AND NEW.purpose_code IS NOT NULL THEN     -- INSERT от новой версии
        SELECT name INTO NEW.purpose FROM loan_purposes WHERE code = NEW.purpose_code;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER sync_purpose
BEFORE INSERT OR UPDATE OF purpose, purpose_code ON loan_applications
FOR EACH ROW EXECUTE FUNCTION trg_sync_purpose();

-- =====================================================================
-- Песочница «Кредитный модуль банка» — физическая модель (PostgreSQL 14+)
-- Запуск в DBeaver: открыть файл → «Выполнить скрипт» (Alt+X / ⌥X).
-- Скрипт пересоздаёт схему credit с нуля: все данные в ней будут удалены.
-- =====================================================================

DROP SCHEMA IF EXISTS credit CASCADE;
CREATE SCHEMA credit;
COMMENT ON SCHEMA credit IS 'Учебный кредитный модуль банка (данные вымышленные)';

SET search_path TO credit;

-- ---------------------------------------------------------------------
-- Служебные функции
-- ---------------------------------------------------------------------

-- «Сегодня» для песочницы. Данные сгенерированы относительно этой даты,
-- чтобы просрочки и статусы не «уезжали» со временем.
CREATE FUNCTION sandbox_today() RETURNS date
LANGUAGE sql IMMUTABLE AS $$ SELECT date '2026-11-25' $$;

-- Контрольная цифра ИИН (Казахстан). Возвращает 0..9 или 10, если такой ИИН невозможен.
-- Алгоритм: веса 1..11, остаток от деления на 11; если вышло 10 — веса 3..11,1,2.
CREATE FUNCTION iin_check_digit(p_first11 text) RETURNS int
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    s int := 0;
    i int;
BEGIN
    FOR i IN 1..11 LOOP
        s := s + i * substr(p_first11, i, 1)::int;
    END LOOP;
    s := s % 11;
    IF s = 10 THEN
        s := 0;
        FOR i IN 1..11 LOOP
            s := s + (((i + 1) % 11) + 1) * substr(p_first11, i, 1)::int;
        END LOOP;
        s := s % 11;
    END IF;
    RETURN s;
END $$;

CREATE FUNCTION iin_is_valid(p_iin text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT p_iin ~ '^\d{12}$'
       AND substr(p_iin, 3, 2)::int BETWEEN 1 AND 12
       AND substr(p_iin, 5, 2)::int BETWEEN 1 AND 31
       AND substr(p_iin, 7, 1)::int BETWEEN 1 AND 6
       AND iin_check_digit(left(p_iin, 11)) = substr(p_iin, 12, 1)::int
$$;
COMMENT ON FUNCTION iin_is_valid(text) IS 'Проверка формата и контрольной цифры ИИН';

-- Собирает ИИН из даты рождения, пола и порядкового номера. NULL, если номер даёт невозможный ИИН.
CREATE FUNCTION make_iin(p_birth date, p_gender char, p_serial int) RETURNS char(12)
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    century_digit int;
    first11 text;
    check_digit int;
BEGIN
    century_digit := CASE
        WHEN extract(year FROM p_birth) < 1900 THEN 1
        WHEN extract(year FROM p_birth) < 2000 THEN 3
        ELSE 5 END + CASE WHEN p_gender = 'F' THEN 1 ELSE 0 END;
    first11 := to_char(p_birth, 'YYMMDD') || century_digit || lpad(p_serial::text, 4, '0');
    check_digit := iin_check_digit(first11);
    IF check_digit = 10 THEN
        RETURN NULL;
    END IF;
    RETURN first11 || check_digit;
END $$;

-- ---------------------------------------------------------------------
-- Справочники
-- ---------------------------------------------------------------------

CREATE TABLE regions (
    id   smallint PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE regions IS 'Регионы (области и города республиканского значения)';

CREATE TABLE branches (
    id        smallint PRIMARY KEY,
    region_id smallint NOT NULL REFERENCES regions (id),
    name      text     NOT NULL UNIQUE,
    opened_on date     NOT NULL
);
COMMENT ON TABLE branches IS 'Филиалы банка';
CREATE INDEX ix_branches_region ON branches (region_id);

CREATE TABLE employees (
    id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id smallint NOT NULL REFERENCES branches (id),
    full_name text     NOT NULL,
    position  text     NOT NULL CHECK (position IN ('credit_expert', 'underwriter', 'branch_head')),
    hired_on  date     NOT NULL
);
COMMENT ON TABLE employees IS 'Сотрудники: кредитные эксперты, андеррайтеры, директора филиалов';
CREATE INDEX ix_employees_branch ON employees (branch_id);

CREATE TABLE loan_products (
    id                  smallint PRIMARY KEY,
    code                text          NOT NULL UNIQUE,
    name                text          NOT NULL,
    client_type         text          NOT NULL CHECK (client_type IN ('individual', 'entrepreneur')),
    currency            char(3)       NOT NULL DEFAULT 'KZT',
    min_amount          numeric(14,2) NOT NULL CHECK (min_amount > 0),
    max_amount          numeric(14,2) NOT NULL,
    min_term_months     smallint      NOT NULL CHECK (min_term_months > 0),
    max_term_months     smallint      NOT NULL,
    annual_rate         numeric(5,2)  NOT NULL CHECK (annual_rate > 0 AND annual_rate < 100),
    requires_collateral boolean       NOT NULL DEFAULT false,
    only_for_women      boolean       NOT NULL DEFAULT false,
    is_active           boolean       NOT NULL DEFAULT true,
    CHECK (max_amount >= min_amount),
    CHECK (max_term_months >= min_term_months)
);
COMMENT ON TABLE loan_products IS 'Кредитные продукты и их параметры';
COMMENT ON COLUMN loan_products.annual_rate IS 'Номинальная годовая ставка, % (не ГЭСВ)';

-- ---------------------------------------------------------------------
-- Клиенты
-- ---------------------------------------------------------------------

CREATE TABLE clients (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iin            char(12)      NOT NULL UNIQUE CHECK (iin_is_valid(iin)),
    last_name      text          NOT NULL,
    first_name     text          NOT NULL,
    middle_name    text,
    birth_date     date          NOT NULL,
    gender         char(1)       NOT NULL CHECK (gender IN ('M', 'F')),
    phone          text          NOT NULL UNIQUE CHECK (phone ~ '^\+77\d{9}$'),
    client_type    text          NOT NULL CHECK (client_type IN ('individual', 'entrepreneur')),
    region_id      smallint      NOT NULL REFERENCES regions (id),
    monthly_income numeric(14,2) NOT NULL CHECK (monthly_income >= 0),
    created_at     timestamptz   NOT NULL
);
COMMENT ON TABLE clients IS 'Клиенты: физлица и ИП';
COMMENT ON COLUMN clients.iin IS 'ИИН — 12 цифр, последняя контрольная';
COMMENT ON COLUMN clients.client_type IS 'individual — физлицо, entrepreneur — ИП';
COMMENT ON COLUMN clients.monthly_income IS 'Подтверждённый ежемесячный доход, KZT';
CREATE INDEX ix_clients_region ON clients (region_id);
-- Индекса по фамилии нет намеренно — это задание урока 4.

-- ---------------------------------------------------------------------
-- Заявки и проверки
-- ---------------------------------------------------------------------

CREATE TABLE loan_applications (
    id                    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id             integer       NOT NULL REFERENCES clients (id),
    product_id            smallint      NOT NULL REFERENCES loan_products (id),
    branch_id             smallint      NOT NULL REFERENCES branches (id),
    expert_id             integer       REFERENCES employees (id),
    channel               text          NOT NULL CHECK (channel IN ('branch', 'mobile_app', 'web')),
    requested_amount      numeric(14,2) NOT NULL CHECK (requested_amount > 0),
    requested_term_months smallint      NOT NULL CHECK (requested_term_months > 0),
    purpose               text          NOT NULL,
    status                text          NOT NULL
        CHECK (status IN ('new', 'scoring', 'approved', 'rejected', 'cancelled', 'issued')),
    score                 smallint      CHECK (score BETWEEN 0 AND 1000),
    reject_reason         text,
    created_at            timestamptz   NOT NULL,
    decided_at            timestamptz,
    CHECK (decided_at IS NULL OR decided_at >= created_at),
    CHECK ((status = 'rejected') = (reject_reason IS NOT NULL)),
    CHECK (channel = 'branch' OR expert_id IS NULL)
);
COMMENT ON TABLE loan_applications IS 'Заявки на кредит';
COMMENT ON COLUMN loan_applications.status IS 'new → scoring → approved/rejected/cancelled → issued';
COMMENT ON COLUMN loan_applications.score IS 'Внутренний скоринговый балл 0..1000';
COMMENT ON COLUMN loan_applications.expert_id IS 'Кредитный эксперт; пусто для онлайн-заявок';
CREATE INDEX ix_applications_client  ON loan_applications (client_id);
CREATE INDEX ix_applications_product ON loan_applications (product_id);
CREATE INDEX ix_applications_branch  ON loan_applications (branch_id);
CREATE INDEX ix_applications_expert  ON loan_applications (expert_id);

CREATE TABLE application_status_history (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id integer     NOT NULL REFERENCES loan_applications (id),
    from_status    text,
    to_status      text        NOT NULL,
    changed_at     timestamptz NOT NULL
);
COMMENT ON TABLE application_status_history IS 'История смены статусов заявки (аудит)';
CREATE INDEX ix_status_history_application ON application_status_history (application_id);

CREATE TABLE credit_bureau_checks (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id integer     NOT NULL REFERENCES loan_applications (id),
    bureau         text        NOT NULL CHECK (bureau IN ('PKB', 'GKB')),
    checked_at     timestamptz NOT NULL,
    response       jsonb       NOT NULL
);
COMMENT ON TABLE credit_bureau_checks IS 'Запросы в кредитные бюро (ПКБ, ГКБ); ответ хранится как JSON';
COMMENT ON COLUMN credit_bureau_checks.response IS 'Ответ бюро: score, overdue_days_max, requests_last_30d, active_loans[]';
CREATE INDEX ix_bureau_checks_application ON credit_bureau_checks (application_id);

-- ---------------------------------------------------------------------
-- Кредиты, график, платежи, залоги
-- ---------------------------------------------------------------------

CREATE TABLE loans (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id  integer       NOT NULL UNIQUE REFERENCES loan_applications (id),
    contract_number text          NOT NULL UNIQUE,
    principal       numeric(14,2) NOT NULL CHECK (principal > 0),
    annual_rate     numeric(5,2)  NOT NULL CHECK (annual_rate > 0),
    term_months     smallint      NOT NULL CHECK (term_months > 0),
    issued_on       date          NOT NULL,
    maturity_date   date          NOT NULL,
    status          text          NOT NULL CHECK (status IN ('active', 'overdue', 'closed', 'written_off')),
    closed_on       date,
    CHECK (maturity_date > issued_on),
    CHECK ((status = 'closed') = (closed_on IS NOT NULL))
);
COMMENT ON TABLE loans IS 'Выданные кредиты (договоры)';
COMMENT ON COLUMN loans.principal IS 'Сумма выдачи (основной долг), KZT';
COMMENT ON COLUMN loans.status IS 'active, overdue — есть просрочка, closed — погашен, written_off — списан (просрочка 180+ дней)';

CREATE TABLE repayment_schedule (
    loan_id        integer       NOT NULL REFERENCES loans (id),
    installment_no smallint      NOT NULL CHECK (installment_no > 0),
    due_date       date          NOT NULL,
    principal_due  numeric(14,2) NOT NULL CHECK (principal_due >= 0),
    interest_due   numeric(14,2) NOT NULL CHECK (interest_due >= 0),
    total_due      numeric(14,2) GENERATED ALWAYS AS (principal_due + interest_due) STORED,
    PRIMARY KEY (loan_id, installment_no)
);
COMMENT ON TABLE repayment_schedule IS 'График погашения (аннуитет): один ряд — один ежемесячный платёж';

CREATE TABLE payments (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id        integer       NOT NULL,
    installment_no smallint      NOT NULL,
    paid_at        timestamptz   NOT NULL,
    amount         numeric(14,2) NOT NULL CHECK (amount > 0),
    channel        text          NOT NULL CHECK (channel IN ('branch', 'mobile_app', 'terminal', 'auto_debit')),
    FOREIGN KEY (loan_id, installment_no) REFERENCES repayment_schedule (loan_id, installment_no)
);
COMMENT ON TABLE payments IS 'Фактические платежи клиентов по графику';
-- Индекса по loan_id нет намеренно — это задание урока 4.

CREATE TABLE collaterals (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id         integer       NOT NULL REFERENCES loans (id),
    type            text          NOT NULL CHECK (type IN ('real_estate', 'vehicle', 'livestock', 'equipment')),
    description     text          NOT NULL,
    appraised_value numeric(14,2) NOT NULL CHECK (appraised_value > 0),
    appraised_on    date          NOT NULL
);
COMMENT ON TABLE collaterals IS 'Залоги по кредитам';
CREATE INDEX ix_collaterals_loan ON collaterals (loan_id);

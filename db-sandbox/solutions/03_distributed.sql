-- Урок 03. Проектирование распределённых БД.
-- Монолитная схема credit делится на 4 микросервиса. В реальности у каждого — своя база
-- (часто свой сервер); здесь для наглядности — своя схема svc_*.
-- Правило: сервис читает и пишет только свою схему. Между сервисами нет FOREIGN KEY —
-- ссылки хранятся как «внешний id», а данные другого сервиса получают через API или события.

DROP SCHEMA IF EXISTS svc_client, svc_origination, svc_loan, svc_payment CASCADE;

-- ---------------------------------------------------------------------
-- 1. Client Service — клиенты (мастер-данные)
-- ---------------------------------------------------------------------
CREATE SCHEMA svc_client;
CREATE TABLE svc_client.clients (
    id             integer PRIMARY KEY,
    iin            char(12)      NOT NULL UNIQUE,
    full_name      text          NOT NULL,
    birth_date     date          NOT NULL,
    phone          text          NOT NULL,
    client_type    text          NOT NULL,
    region_name    text          NOT NULL,         -- справочник регионов скопирован внутрь сервиса
    monthly_income numeric(14,2) NOT NULL,
    updated_at     timestamptz   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. Origination Service — приём и рассмотрение заявок
-- ---------------------------------------------------------------------
CREATE SCHEMA svc_origination;
CREATE TABLE svc_origination.applications (
    id                    integer PRIMARY KEY,
    client_id             integer       NOT NULL,  -- id из Client Service, БЕЗ внешнего ключа
    client_iin            char(12)      NOT NULL,  -- снимок на момент подачи: заявка не зависит от правок профиля
    client_income         numeric(14,2) NOT NULL,  -- снимок дохода для скоринга
    product_code          text          NOT NULL,
    requested_amount      numeric(14,2) NOT NULL,
    requested_term_months smallint      NOT NULL,
    status                text          NOT NULL,
    score                 smallint,
    created_at            timestamptz   NOT NULL,
    decided_at            timestamptz
);
CREATE TABLE svc_origination.bureau_checks (
    id             integer PRIMARY KEY,
    application_id integer     NOT NULL REFERENCES svc_origination.applications (id),  -- внутри сервиса FK можно
    bureau         text        NOT NULL,
    response       jsonb       NOT NULL
);

-- ---------------------------------------------------------------------
-- 3. Loan Service — договоры, графики, залоги
-- ---------------------------------------------------------------------
CREATE SCHEMA svc_loan;
CREATE TABLE svc_loan.loans (
    id              integer PRIMARY KEY,
    application_id  integer       NOT NULL UNIQUE, -- id из Origination, без FK
    client_id       integer       NOT NULL,        -- денормализация: Loan Service отвечает «кредиты клиента» без вызова Origination
    contract_number text          NOT NULL UNIQUE,
    product_code    text          NOT NULL,
    principal       numeric(14,2) NOT NULL,
    annual_rate     numeric(5,2)  NOT NULL,
    term_months     smallint      NOT NULL,
    issued_on       date          NOT NULL,
    status          text          NOT NULL
);
CREATE TABLE svc_loan.schedule (
    loan_id        integer       NOT NULL REFERENCES svc_loan.loans (id),
    installment_no smallint      NOT NULL,
    due_date       date          NOT NULL,
    principal_due  numeric(14,2) NOT NULL,
    interest_due   numeric(14,2) NOT NULL,
    paid           boolean       NOT NULL DEFAULT false,  -- обновляется по событию PaymentReceived
    PRIMARY KEY (loan_id, installment_no)
);

-- ---------------------------------------------------------------------
-- 4. Payment Service — приём платежей
-- ---------------------------------------------------------------------
CREATE SCHEMA svc_payment;
CREATE TABLE svc_payment.payments (
    id              integer PRIMARY KEY,
    contract_number text          NOT NULL,        -- платёж приходит по номеру договора из терминала/приложения
    installment_no  smallint      NOT NULL,
    amount          numeric(14,2) NOT NULL,
    paid_at         timestamptz   NOT NULL,
    channel         text          NOT NULL,
    idempotency_key text          NOT NULL UNIQUE  -- повтор того же платежа от терминала не создаёт дубль
);

-- Transactional outbox: событие пишется в ту же транзакцию, что и платёж,
-- а отдельный процесс доставляет его в брокер (Kafka/RabbitMQ). Так событие не теряется.
CREATE TABLE svc_payment.outbox (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type   text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);

-- ---------------------------------------------------------------------
-- Наполняем сервисы из монолита (это и есть миграция в микросервисы — см. урок 02)
-- ---------------------------------------------------------------------
INSERT INTO svc_client.clients (id, iin, full_name, birth_date, phone, client_type, region_name, monthly_income)
SELECT c.id, c.iin, concat_ws(' ', c.last_name, c.first_name, c.middle_name), c.birth_date, c.phone,
       c.client_type, r.name, c.monthly_income
FROM credit.clients c JOIN credit.regions r ON r.id = c.region_id;

INSERT INTO svc_origination.applications
SELECT a.id, a.client_id, c.iin, c.monthly_income, p.code, a.requested_amount, a.requested_term_months,
       a.status, a.score, a.created_at, a.decided_at
FROM credit.loan_applications a
JOIN credit.clients c       ON c.id = a.client_id
JOIN credit.loan_products p ON p.id = a.product_id;

INSERT INTO svc_origination.bureau_checks
SELECT id, application_id, bureau, response FROM credit.credit_bureau_checks;

INSERT INTO svc_loan.loans
SELECT l.id, l.application_id, a.client_id, l.contract_number, p.code, l.principal, l.annual_rate,
       l.term_months, l.issued_on, l.status
FROM credit.loans l
JOIN credit.loan_applications a ON a.id = l.application_id
JOIN credit.loan_products p     ON p.id = a.product_id;

INSERT INTO svc_loan.schedule
SELECT s.loan_id, s.installment_no, s.due_date, s.principal_due, s.interest_due,
       EXISTS (SELECT 1 FROM credit.payments pm
               WHERE pm.loan_id = s.loan_id AND pm.installment_no = s.installment_no)
FROM credit.repayment_schedule s;

INSERT INTO svc_payment.payments
SELECT p.id, l.contract_number, p.installment_no, p.amount, p.paid_at, p.channel,
       'legacy-' || p.id
FROM credit.payments p JOIN credit.loans l ON l.id = p.loan_id;

-- ---------------------------------------------------------------------
-- Сценарий: клиент платит в терминале. Что происходит в каждом сервисе.
-- (внутри транзакции с откатом — данные не меняются)
-- ---------------------------------------------------------------------
BEGIN;

-- Payment Service: платёж и событие — в ОДНОЙ локальной транзакции
WITH next_due AS (
    SELECT l.contract_number, s.installment_no, s.principal_due + s.interest_due AS amount
    FROM svc_loan.loans l
    JOIN svc_loan.schedule s ON s.loan_id = l.id AND NOT s.paid
    WHERE l.status = 'active'
    ORDER BY l.id, s.installment_no
    LIMIT 1
), pay AS (
    INSERT INTO svc_payment.payments (id, contract_number, installment_no, amount, paid_at, channel, idempotency_key)
    SELECT 900000001, contract_number, installment_no, amount, now(), 'terminal', 'term-42-20261125-0001'
    FROM next_due
    RETURNING *
)
INSERT INTO svc_payment.outbox (event_type, payload)
SELECT 'PaymentReceived', jsonb_build_object(
           'contractNumber', contract_number, 'installmentNo', installment_no,
           'amount', amount, 'paidAt', paid_at)
FROM pay;

-- Повтор того же запроса от терминала (сеть «моргнула») — дубль не создаётся
INSERT INTO svc_payment.payments (id, contract_number, installment_no, amount, paid_at, channel, idempotency_key)
VALUES (900000002, 'X', 1, 1, now(), 'terminal', 'term-42-20261125-0001')
ON CONFLICT (idempotency_key) DO NOTHING;

-- Loan Service получил событие из брокера и отметил строку графика (у себя, в своей транзакции)
UPDATE svc_loan.schedule s
SET paid = true
FROM svc_payment.outbox o
JOIN svc_loan.loans l ON l.contract_number = o.payload ->> 'contractNumber'
WHERE o.event_type = 'PaymentReceived' AND o.published_at IS NULL
  AND s.loan_id = l.id AND s.installment_no = (o.payload ->> 'installmentNo')::smallint;

SELECT event_type, payload FROM svc_payment.outbox;
SELECT count(*) AS payments_with_same_key FROM svc_payment.payments WHERE idempotency_key = 'term-42-20261125-0001';

ROLLBACK;

-- ---------------------------------------------------------------------
-- Запрос «через сервисы»: досье клиента для оператора колл-центра.
-- В монолите — один JOIN. В микросервисах — API Composition: шлюз опрашивает 3 сервиса
-- и склеивает ответы. Ниже — что вернул бы каждый сервис (отдельные запросы, а не JOIN!).
-- ---------------------------------------------------------------------
SELECT id, full_name, region_name FROM svc_client.clients WHERE id = 5;                 -- Client Service
SELECT id, product_code, status FROM svc_origination.applications WHERE client_id = 5;  -- Origination
SELECT contract_number, principal, status FROM svc_loan.loans WHERE client_id = 5;      -- Loan Service

-- Если такой отчёт нужен часто и по всем клиентам — строят отдельную read-модель (CQRS):
-- витрину, которая собирается из событий всех сервисов и живёт с небольшой задержкой.

-- =====================================================================
-- Песочница «Кредитный модуль банка» — тестовые данные
-- Запускать после 01_schema.sql. Все люди и номера вымышленные.
-- Генерация детерминирована (setseed): на одной версии PostgreSQL
-- данные получаются одинаковыми при каждом запуске.
-- =====================================================================

SET search_path TO credit;
SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- Справочники
-- ---------------------------------------------------------------------

INSERT INTO regions (id, name)
SELECT row_number() OVER (), r
FROM unnest(ARRAY[
    'Алматы', 'Астана', 'Шымкент', 'Алматинская обл.', 'Жамбылская обл.',
    'Туркестанская обл.', 'Кызылординская обл.', 'Актюбинская обл.', 'Атырауская обл.',
    'Мангистауская обл.', 'Западно-Казахстанская обл.', 'Костанайская обл.',
    'Карагандинская обл.', 'Павлодарская обл.', 'Северо-Казахстанская обл.',
    'Восточно-Казахстанская обл.', 'Акмолинская обл.', 'Абайская обл.',
    'Жетысуская обл.', 'Улытауская обл.'
]) AS r;

INSERT INTO branches (id, region_id, name, opened_on)
SELECT id, id, 'Филиал ' || name, date '2012-01-01' + (random() * 3000)::int
FROM regions;

-- Имена для генерации
CREATE TEMP TABLE names_male_last  (n text);
CREATE TEMP TABLE names_first      (n text, gender char(1));
CREATE TEMP TABLE names_father     (n text);
INSERT INTO names_male_last SELECT unnest(ARRAY[
    'Ахметов','Жумабаев','Сериков','Нурланов','Касымов','Омаров','Искаков','Бекенов',
    'Абдрахманов','Тулегенов','Садыков','Мухаметов','Есенов','Байжанов','Кенжебаев',
    'Иванов','Петров','Смирнов','Кузнецов','Попов','Соколов','Лебедев','Волков',
    'Султанов','Ермеков','Альжанов','Темирбаев','Нуриев','Каримов','Утепов']);
INSERT INTO names_first SELECT unnest(ARRAY[
    'Ерлан','Нурлан','Асхат','Даурен','Айдар','Тимур','Руслан','Арман','Болат','Канат',
    'Санжар','Алихан','Дмитрий','Сергей','Алексей','Марат','Ержан','Галым']), 'M';
INSERT INTO names_first SELECT unnest(ARRAY[
    'Айгерим','Динара','Жанар','Гульнара','Асель','Мадина','Сауле','Алия','Камила',
    'Айжан','Дана','Елена','Ольга','Анна','Мария','Томирис','Жансая','Гаухар']), 'F';
INSERT INTO names_father SELECT unnest(ARRAY[
    'Серик','Ерлан','Нурлан','Асхат','Бахыт','Канат','Марат','Даурен','Ержан','Айдар',
    'Тимур','Руслан','Арман','Галым','Болат']);

INSERT INTO employees (branch_id, full_name, position, hired_on)
SELECT b.id,
       (SELECT n FROM names_male_last ORDER BY random() + b.id * 0 + p.k * 0 LIMIT 1) || ' ' ||
       (SELECT n FROM names_first WHERE gender = 'M' ORDER BY random() + b.id * 0 + p.k * 0 LIMIT 1),
       p.position,
       date '2015-01-01' + (random() * 3500)::int
FROM branches b
CROSS JOIN (VALUES (1, 'branch_head'), (2, 'underwriter'), (3, 'credit_expert'),
                   (4, 'credit_expert'), (5, 'credit_expert')) AS p(k, position)
ORDER BY b.id, p.k;

INSERT INTO loan_products
    (id, code, name, client_type, min_amount, max_amount, min_term_months, max_term_months,
     annual_rate, requires_collateral, only_for_women)
VALUES
    (1, 'CONSUMER',  'Потребительский кредит',     'individual',   100000,  5000000,  6, 36, 34.90, false, false),
    (2, 'REFIN',     'Рефинансирование',           'individual',   300000,  7000000, 12, 48, 29.90, false, false),
    (3, 'MICRO_IP',  'Микрокредит для ИП',         'entrepreneur', 300000, 15000000,  6, 36, 28.00, false, false),
    (4, 'AGRO',      'Агрокредит',                 'entrepreneur', 500000, 20000000, 12, 48, 22.00, true,  false),
    (5, 'WOMEN_BIZ', 'Бизнес-кредит для женщин',   'entrepreneur', 200000, 10000000,  6, 36, 24.50, false, true);

-- ---------------------------------------------------------------------
-- Клиенты (~5000)
-- ---------------------------------------------------------------------

CREATE TEMP TABLE gen_clients AS
SELECT n,
       g.gender,
       g.birth_date,
       CASE WHEN random() < 0.45 THEN 'entrepreneur' ELSE 'individual' END AS client_type,
       1 + floor(random() * 20)::int AS region_id,
       random() AS r_last, random() AS r_first, random() AS r_father, random() AS r_income,
       timestamptz '2020-01-01 09:00+05' + random() * interval '2150 days' AS created_at
FROM generate_series(1, 4999) AS n
CROSS JOIN LATERAL (
    SELECT CASE WHEN random() < 0.5 THEN 'M' ELSE 'F' END AS gender,
           date '1960-01-01' + (random() * 16400)::int + n * 0 AS birth_date
) AS g;

INSERT INTO clients
    (iin, last_name, first_name, middle_name, birth_date, gender, phone,
     client_type, region_id, monthly_income, created_at)
SELECT coalesce(make_iin(c.birth_date, c.gender, c.n), make_iin(c.birth_date, c.gender, c.n + 5000)),
       ln.n || CASE WHEN c.gender = 'F' THEN 'а' ELSE '' END,
       fn.n,
       CASE WHEN c.r_father < 0.08 THEN NULL
            ELSE fa.n || CASE WHEN c.gender = 'F' THEN 'овна' ELSE 'ович' END END,
       c.birth_date,
       c.gender,
       '+77' || (ARRAY['01','02','05','07','08','71','75','76','77','78'])[1 + c.n % 10]
             || lpad(c.n::text, 7, '0'),
       c.client_type,
       c.region_id,
       round((CASE WHEN c.client_type = 'entrepreneur' THEN 350000 ELSE 180000 END
              * (0.4 + 2.2 * c.r_income * c.r_income))::numeric, -3),
       c.created_at
FROM gen_clients c
JOIN LATERAL (SELECT n FROM names_male_last OFFSET floor(c.r_last * 30)::int LIMIT 1) ln ON true
JOIN LATERAL (SELECT n FROM names_first WHERE gender = c.gender
              OFFSET floor(c.r_first * 18)::int LIMIT 1) fn ON true
JOIN LATERAL (SELECT n FROM names_father OFFSET floor(c.r_father * 15)::int LIMIT 1) fa ON true
WHERE coalesce(make_iin(c.birth_date, c.gender, c.n), make_iin(c.birth_date, c.gender, c.n + 5000)) IS NOT NULL
ORDER BY c.n;

-- ---------------------------------------------------------------------
-- Заявки (~8000)
-- ---------------------------------------------------------------------

CREATE TEMP TABLE gen_apps AS
SELECT a.n,
       cl.id AS client_id,
       cl.client_type, cl.gender, cl.region_id, cl.monthly_income,
       random() AS r_product, random() AS r_amount, random() AS r_term,
       random() AS r_channel, random() AS r_expert, random() AS r_status, random() AS r_purpose,
       (300 + 300 * random() + 300 * random())::int AS score,
       greatest(cl.created_at, timestamptz '2024-01-01 09:00+05')
           + random() * (timestamptz '2026-11-20 18:00+05'
                         - greatest(cl.created_at, timestamptz '2024-01-01 09:00+05')) AS created_at,
       interval '1 hour' * (1 + floor(random() * 72)) AS decision_delay
FROM (
    -- случайный клиент на каждую заявку: часть клиентов получит несколько заявок
    SELECT n, 1 + floor(random() * (SELECT max(id) FROM clients))::int AS client_id
    FROM generate_series(1, 8000) AS n
) a
JOIN clients cl ON cl.id = a.client_id;

INSERT INTO loan_applications
    (client_id, product_id, branch_id, expert_id, channel, requested_amount,
     requested_term_months, purpose, status, score, reject_reason, created_at, decided_at)
SELECT x.client_id,
       x.product_id,
       x.region_id,
       CASE WHEN x.channel = 'branch' THEN
           (SELECT e.id FROM employees e
            WHERE e.branch_id = x.region_id AND e.position = 'credit_expert'
            ORDER BY e.id OFFSET floor(x.r_expert * 3)::int LIMIT 1)
       END,
       x.channel,
       x.amount,
       x.term,
       x.purpose,
       x.status,
       CASE WHEN x.status IN ('new') THEN NULL ELSE x.score END,
       CASE WHEN x.status = 'rejected' THEN
           CASE WHEN x.score < 450 THEN 'Низкий скоринговый балл'
                ELSE 'Высокая долговая нагрузка' END
       END,
       x.created_at,
       CASE WHEN x.status IN ('new', 'scoring') THEN NULL ELSE x.created_at + x.decision_delay END
FROM (
    SELECT g.*,
           p.id AS product_id,
           round((p.min_amount + (p.max_amount - p.min_amount) * g.r_amount ^ 3)::numeric, -4) AS amount,
           (p.min_term_months
            + floor(g.r_term * ((p.max_term_months - p.min_term_months) / 6 + 1))::int * 6)::smallint AS term,
           CASE WHEN g.r_channel < 0.55 THEN 'branch'
                WHEN g.r_channel < 0.90 THEN 'mobile_app'
                ELSE 'web' END AS channel,
           CASE p.code
               WHEN 'CONSUMER'  THEN (ARRAY['Ремонт жилья','Покупка техники','Лечение','Обучение'])[1 + floor(g.r_purpose * 4)::int]
               WHEN 'REFIN'     THEN 'Рефинансирование займов'
               WHEN 'MICRO_IP'  THEN (ARRAY['Пополнение оборотных средств','Покупка оборудования','Аренда торговой точки'])[1 + floor(g.r_purpose * 3)::int]
               WHEN 'AGRO'      THEN (ARRAY['Покупка скота','Посевная кампания','Покупка техники для хозяйства'])[1 + floor(g.r_purpose * 3)::int]
               ELSE                  (ARRAY['Открытие салона красоты','Пошив одежды','Пополнение оборотных средств'])[1 + floor(g.r_purpose * 3)::int]
           END AS purpose,
           CASE
               WHEN g.created_at > timestamptz '2026-11-19 00:00+05' AND g.r_status < 0.5 THEN 'new'
               WHEN g.created_at > timestamptz '2026-11-19 00:00+05' THEN 'scoring'
               WHEN g.score < 450 THEN 'rejected'
               WHEN g.r_status < 0.06 THEN 'cancelled'
               WHEN g.r_status < 0.14 THEN 'rejected'
               WHEN g.created_at > timestamptz '2026-11-05 00:00+05' AND g.r_status < 0.40 THEN 'approved'
               ELSE 'issued'
           END AS status
    FROM gen_apps g
    JOIN LATERAL (
        SELECT lp.* FROM loan_products lp
        WHERE lp.client_type = g.client_type
          AND (NOT lp.only_for_women OR g.gender = 'F')
        ORDER BY lp.id
        OFFSET floor(g.r_product * (
            SELECT count(*) FROM loan_products lp2
            WHERE lp2.client_type = g.client_type AND (NOT lp2.only_for_women OR g.gender = 'F')))::int
        LIMIT 1
    ) p ON true
) x
ORDER BY x.created_at;

-- Срок не должен выходить за максимум продукта (округление до 6 мес. мог его превысить)
UPDATE loan_applications a
SET requested_term_months = p.max_term_months
FROM loan_products p
WHERE p.id = a.product_id AND a.requested_term_months > p.max_term_months;

-- История статусов
INSERT INTO application_status_history (application_id, from_status, to_status, changed_at)
SELECT id, NULL, 'new', created_at FROM loan_applications
UNION ALL
SELECT id, 'new', 'scoring', created_at + interval '5 minutes'
FROM loan_applications WHERE status <> 'new'
UNION ALL
SELECT id, 'scoring', CASE WHEN status = 'issued' THEN 'approved' ELSE status END, decided_at
FROM loan_applications WHERE status IN ('approved', 'rejected', 'cancelled', 'issued')
UNION ALL
SELECT id, 'approved', 'issued', decided_at + interval '1 day'
FROM loan_applications WHERE status = 'issued'
ORDER BY 4;

-- Проверки в кредитных бюро: ПКБ по каждой рассмотренной заявке, ГКБ — примерно по трети
INSERT INTO credit_bureau_checks (application_id, bureau, checked_at, response)
SELECT a.id, b.bureau, a.created_at + interval '10 minutes',
       jsonb_build_object(
           'score', greatest(200, least(950, a.score + (random() * 120 - 60)::int)),
           'overdue_days_max', CASE WHEN a.score < 450 THEN (random() * 120)::int
                                    WHEN random() < 0.1 THEN (random() * 30)::int ELSE 0 END,
           'requests_last_30d', (random() * 6)::int,
           'active_loans', coalesce(al.loans, '[]'::jsonb)
       )
FROM loan_applications a
CROSS JOIN LATERAL (
    SELECT 'PKB' AS bureau
    UNION ALL
    SELECT 'GKB' WHERE a.id % 3 = 0
) b
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
               'lender', (ARRAY['Банк А','Банк Б','МФО В','Банк Г','МФО Д'])[1 + (a.id + k) % 5],
               'type', (ARRAY['consumer','card','mortgage','auto','micro'])[1 + (a.id * k) % 5],
               'balance', round((50000 + random() * 3000000)::numeric, -3),
               'monthly_payment', round((5000 + random() * 150000)::numeric, -2),
               'overdue_days', CASE WHEN a.score < 450 AND k = 1 THEN 15 + (a.id % 60) ELSE 0 END
           ) ORDER BY k) AS loans
    FROM generate_series(1, a.id % 4) AS k
) al ON true
WHERE a.status <> 'new';

-- ---------------------------------------------------------------------
-- Кредиты
-- ---------------------------------------------------------------------

INSERT INTO loans
    (application_id, contract_number, principal, annual_rate, term_months,
     issued_on, maturity_date, status)
SELECT a.id,
       'CR-' || to_char(a.decided_at + interval '1 day', 'YYYY') || '-' || lpad(a.id::text, 6, '0'),
       CASE WHEN random() < 0.15 THEN round(a.requested_amount * 0.7, -4) ELSE a.requested_amount END,
       p.annual_rate - CASE WHEN a.score >= 750 THEN 2 ELSE 0 END,
       a.requested_term_months,
       (a.decided_at + interval '1 day')::date,
       ((a.decided_at + interval '1 day')::date + make_interval(months => a.requested_term_months))::date,
       'active'
FROM loan_applications a
JOIN loan_products p ON p.id = a.product_id
WHERE a.status = 'issued'
ORDER BY a.decided_at;

-- Аннуитетный график: A = P·r / (1 − (1+r)^−n), остаток после k платежей
-- B(k) = P·(1+r)^k − A·((1+r)^k − 1)/r; проценты = B(k−1)·r, основной долг = B(k−1) − B(k)
INSERT INTO repayment_schedule (loan_id, installment_no, due_date, principal_due, interest_due)
SELECT l.id,
       k,
       (l.issued_on + make_interval(months => k))::date,
       round((bal_prev - bal)::numeric, 2),
       round((bal_prev * r)::numeric, 2)
FROM loans l
CROSS JOIN LATERAL (SELECT l.annual_rate::float8 / 1200 AS r) rr
CROSS JOIN LATERAL (SELECT l.principal::float8 * r / (1 - (1 + r) ^ (-l.term_months)) AS a) ann
CROSS JOIN LATERAL generate_series(1, l.term_months) AS k
CROSS JOIN LATERAL (
    SELECT l.principal::float8 * (1 + r) ^ (k - 1) - a * ((1 + r) ^ (k - 1) - 1) / r AS bal_prev,
           greatest(0, l.principal::float8 * (1 + r) ^ k - a * ((1 + r) ^ k - 1) / r) AS bal
) b;

-- Последний платёж закрывает копейки округления, чтобы сумма основного долга = principal
UPDATE repayment_schedule s
SET principal_due = s.principal_due + (l.principal - t.total)
FROM loans l
JOIN (SELECT loan_id, sum(principal_due) AS total FROM repayment_schedule GROUP BY loan_id) t
  ON t.loan_id = l.id
WHERE s.loan_id = l.id AND s.installment_no = l.term_months AND t.total <> l.principal;

-- ---------------------------------------------------------------------
-- Платежи: дисциплинированные (≈78%), опаздывающие (≈14%), дефолтные (≈8%)
-- ---------------------------------------------------------------------

CREATE TEMP TABLE loan_behaviour AS
SELECT id AS loan_id,
       CASE WHEN r < 0.78 THEN 'good' WHEN r < 0.92 THEN 'late' ELSE 'default' END AS kind,
       2 + floor(random() * greatest(term_months - 2, 1))::int AS stop_after,
       r_channel
FROM (SELECT id, term_months, random() AS r, random() AS r_channel FROM loans) t;

INSERT INTO payments (loan_id, installment_no, paid_at, amount, channel)
SELECT s.loan_id, s.installment_no, p.paid_at, s.total_due,
       CASE WHEN b.r_channel < 0.45 THEN 'mobile_app' WHEN b.r_channel < 0.70 THEN 'terminal'
            WHEN b.r_channel < 0.85 THEN 'auto_debit' ELSE 'branch' END
FROM repayment_schedule s
JOIN loan_behaviour b ON b.loan_id = s.loan_id
CROSS JOIN LATERAL (
    SELECT s.due_date::timestamptz + interval '10 hours'
           + CASE b.kind
                 WHEN 'late' THEN interval '1 day' * (1 + floor(random() * 25))
                 ELSE interval '-1 day' * floor(random() * 4)
             END AS paid_at
) p
WHERE s.due_date <= sandbox_today()
  AND (b.kind <> 'default' OR s.installment_no <= b.stop_after)
  AND p.paid_at::date <= sandbox_today()
ORDER BY p.paid_at;

-- Статусы кредитов по факту платежей
UPDATE loans l
SET status = CASE
        WHEN u.oldest_unpaid IS NULL AND l.maturity_date <= sandbox_today() THEN 'closed'
        WHEN u.oldest_unpaid IS NULL THEN 'active'
        WHEN u.oldest_unpaid < sandbox_today() - 180 THEN 'written_off'
        ELSE 'overdue'
    END,
    closed_on = CASE WHEN u.oldest_unpaid IS NULL AND l.maturity_date <= sandbox_today()
                     THEN u.last_paid END
FROM (
    SELECT s.loan_id,
           min(s.due_date) FILTER (WHERE p.id IS NULL AND s.due_date < sandbox_today()) AS oldest_unpaid,
           max(p.paid_at)::date AS last_paid
    FROM repayment_schedule s
    LEFT JOIN payments p ON p.loan_id = s.loan_id AND p.installment_no = s.installment_no
    GROUP BY s.loan_id
) u
WHERE u.loan_id = l.id;

-- ---------------------------------------------------------------------
-- Залоги: все агрокредиты и крупные кредиты ИП (> 5 млн)
-- ---------------------------------------------------------------------

INSERT INTO collaterals (loan_id, type, description, appraised_value, appraised_on)
SELECT l.id, c.type, c.description,
       round((l.principal * (1.2 + random() * 0.8))::numeric, -3),
       l.issued_on - 3
FROM loans l
JOIN loan_applications a ON a.id = l.application_id
JOIN loan_products p ON p.id = a.product_id
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        ('livestock',   'Крупный рогатый скот'),
        ('equipment',   'Сельхозтехника'),
        ('real_estate', 'Нежилое помещение'),
        ('vehicle',     'Грузовой автомобиль')
    ) v(type, description)
    -- агро: скот или техника; ИП: недвижимость или автомобиль
    OFFSET CASE WHEN p.code = 'AGRO' THEN l.id % 2 ELSE 2 + l.id % 2 END
    LIMIT 1
) c
WHERE p.code = 'AGRO' OR (p.code = 'MICRO_IP' AND l.principal > 5000000);

DROP TABLE names_male_last, names_first, names_father, gen_clients, gen_apps, loan_behaviour;

ANALYZE;

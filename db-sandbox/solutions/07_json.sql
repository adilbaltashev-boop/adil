-- Урок 07. Маппинг данных: БД и JSON — решения.
SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)

-- ---------------------------------------------------------------------
-- A. Читаем JSON, который пришёл извне (ответы кредитных бюро)
-- ---------------------------------------------------------------------

-- A1. Посмотреть один ответ целиком (в DBeaver двойной клик по ячейке откроет JSON-редактор)
SELECT application_id, bureau, jsonb_pretty(response)
FROM credit_bureau_checks
ORDER BY id
LIMIT 3;

-- A2. Вытащить поля: -> возвращает JSON, ->> возвращает текст
SELECT application_id,
       response -> 'score'                   AS score_json,
       (response ->> 'score')::int           AS score,
       (response ->> 'overdue_days_max')::int AS overdue_days_max,
       jsonb_array_length(response -> 'active_loans') AS active_loans_cnt
FROM credit_bureau_checks
WHERE bureau = 'PKB'
LIMIT 10;

-- A3. Заявки, по которым бюро показало просрочку больше 30 дней.
-- По одной заявке бывает два ответа (ПКБ и ГКБ) — группируем, иначе заявка выведется дважды.
SELECT a.id, a.status, max((b.response ->> 'overdue_days_max')::int) AS overdue_days_max
FROM credit_bureau_checks b
JOIN loan_applications a ON a.id = b.application_id
GROUP BY a.id, a.status
HAVING max((b.response ->> 'overdue_days_max')::int) > 30
ORDER BY overdue_days_max DESC
LIMIT 20;

-- A4. Развернуть массив active_loans в строки — по одной строке на чужой кредит клиента
SELECT b.application_id,
       l ->> 'lender'                    AS lender,
       l ->> 'type'                      AS loan_type,
       (l ->> 'balance')::numeric        AS balance,
       (l ->> 'monthly_payment')::numeric AS monthly_payment
FROM credit_bureau_checks b
CROSS JOIN LATERAL jsonb_array_elements(b.response -> 'active_loans') AS l
WHERE b.bureau = 'PKB'
ORDER BY b.application_id
LIMIT 20;

-- A5. Коэффициент долговой нагрузки по выданным кредитам:
-- (платежи по чужим кредитам из ПКБ + наш ежемесячный платёж) / доход клиента
WITH other_debt AS (
    SELECT b.application_id,
           coalesce(sum((l ->> 'monthly_payment')::numeric), 0) AS other_payments
    FROM credit_bureau_checks b
    LEFT JOIN LATERAL jsonb_array_elements(b.response -> 'active_loans') AS l ON true
    WHERE b.bureau = 'PKB'
    GROUP BY b.application_id
)
SELECT l.contract_number,
       c.monthly_income,
       od.other_payments,
       s.total_due AS our_payment,
       round((od.other_payments + s.total_due) / nullif(c.monthly_income, 0), 2) AS debt_to_income
FROM loans l
JOIN loan_applications a  ON a.id = l.application_id
JOIN clients c            ON c.id = a.client_id
JOIN other_debt od        ON od.application_id = a.id
JOIN repayment_schedule s ON s.loan_id = l.id AND s.installment_no = 1
ORDER BY debt_to_income DESC
LIMIT 20;

-- A6. Поиск внутри JSON оператором @> (содержит) — какие заявки имеют ипотеку в другом банке
SELECT count(DISTINCT application_id) AS apps_with_mortgage
FROM credit_bureau_checks
WHERE response -> 'active_loans' @> '[{"type": "mortgage"}]';

-- ---------------------------------------------------------------------
-- B. Собираем JSON для API из таблиц
-- Метод: GET /api/v1/clients/{clientId}/loans
-- ---------------------------------------------------------------------

-- B1. Ответ API для одного клиента (подставь любой client_id с кредитами, например 5)
SELECT json_build_object(
    'clientId',   c.id,
    'fullName',   concat_ws(' ', c.last_name, c.first_name, c.middle_name),
    'iinMasked',  left(c.iin, 6) || '******',
    'loans', coalesce((
        SELECT json_agg(json_build_object(
                   'contractNumber', l.contract_number,
                   'product',        json_build_object('code', p.code, 'name', p.name),
                   'principal',      l.principal,
                   'currency',       p.currency,
                   'annualRate',     l.annual_rate,
                   'issuedOn',       l.issued_on,
                   'maturityDate',   l.maturity_date,
                   'status',         upper(l.status),
                   'nextPayment', (
                       SELECT json_build_object('dueDate', s.due_date, 'amount', s.total_due)
                       FROM repayment_schedule s
                       LEFT JOIN payments pm ON pm.loan_id = s.loan_id AND pm.installment_no = s.installment_no
                       WHERE s.loan_id = l.id AND pm.id IS NULL
                       ORDER BY s.installment_no
                       LIMIT 1)
               ) ORDER BY l.issued_on DESC)
        FROM loans l
        JOIN loan_applications a ON a.id = l.application_id
        JOIN loan_products p     ON p.id = a.product_id
        WHERE a.client_id = c.id
    ), '[]'::json)
) AS api_response
FROM clients c
WHERE c.id = 5;

-- B2. Обратная задача: разобрать входящий JSON заявки из мобильного приложения в строку таблицы
-- (так аналитик проверяет, что все поля запроса ложатся в колонки).
-- Поменяй ИИН на несуществующий (например, '000000000000') и посмотри, что вернётся.
WITH request AS (
    -- так выглядит тело запроса:
    -- {"clientIin": "<ИИН>", "productCode": "MICRO_IP", "amount": 1500000,
    --  "termMonths": 24, "purpose": "Покупка оборудования", "channel": "MOBILE_APP"}
    -- ИИН берём у клиента id = 5, чтобы пример работал на любой версии PostgreSQL
    SELECT jsonb_build_object(
               'clientIin',   (SELECT iin FROM clients WHERE id = 5),
               'productCode', 'MICRO_IP',
               'amount',      1500000,
               'termMonths',  24,
               'purpose',     'Покупка оборудования',
               'channel',     'MOBILE_APP') AS body
)
SELECT c.id                         AS client_id,
       p.id                         AS product_id,
       (r.body ->> 'amount')::numeric     AS requested_amount,
       (r.body ->> 'termMonths')::smallint AS requested_term_months,
       r.body ->> 'purpose'         AS purpose,
       lower(r.body ->> 'channel')  AS channel,
       c.id IS NOT NULL             AS client_found,
       (r.body ->> 'amount')::numeric BETWEEN p.min_amount AND p.max_amount AS amount_ok
FROM request r
LEFT JOIN clients c       ON c.iin = r.body ->> 'clientIin'
LEFT JOIN loan_products p ON p.code = r.body ->> 'productCode';

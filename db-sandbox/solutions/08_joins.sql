-- Урок 08. JOIN — решения.
SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)

-- 1. INNER JOIN: заявки с ФИО клиента и названием продукта
SELECT a.id, c.last_name || ' ' || c.first_name AS client, p.name AS product,
       a.requested_amount, a.status
FROM loan_applications a
JOIN clients c       ON c.id = a.client_id
JOIN loan_products p ON p.id = a.product_id
ORDER BY a.created_at DESC
LIMIT 20;

-- 2. Цепочка из пяти таблиц: кредит → заявка → клиент → регион, и продукт
SELECT l.contract_number, p.code AS product, r.name AS region, l.principal, l.status
FROM loans l
JOIN loan_applications a ON a.id = l.application_id
JOIN clients c           ON c.id = a.client_id
JOIN regions r           ON r.id = c.region_id
JOIN loan_products p     ON p.id = a.product_id
WHERE l.status = 'overdue'
ORDER BY l.principal DESC;

-- 3. LEFT JOIN … IS NULL (anti-join): клиенты, не подавшие ни одной заявки
SELECT c.id, c.last_name, c.first_name, c.created_at
FROM clients c
LEFT JOIN loan_applications a ON a.client_id = c.id
WHERE a.id IS NULL;
-- то же через NOT EXISTS — читается проще и не ломается от дублей:
SELECT count(*) AS clients_without_applications
FROM clients c
WHERE NOT EXISTS (SELECT 1 FROM loan_applications a WHERE a.client_id = c.id);

-- 4. Кредитные эксперты и число их заявок, включая экспертов без заявок.
-- count(a.id), а не count(*): у эксперта без заявок count(*) вернул бы 1.
SELECT e.full_name, b.name AS branch, count(a.id) AS applications
FROM employees e
JOIN branches b               ON b.id = e.branch_id
LEFT JOIN loan_applications a ON a.expert_id = e.id
WHERE e.position = 'credit_expert'
GROUP BY e.id, e.full_name, b.name
ORDER BY applications;

-- 5. Ловушка: условие на правую таблицу LEFT JOIN в WHERE превращает его в INNER JOIN.
-- Задача: все клиенты и число их заявок через мобильное приложение (включая нули).
-- Неправильно — клиенты без мобильных заявок пропадают:
SELECT count(*) AS rows_wrong
FROM (SELECT c.id
      FROM clients c
      LEFT JOIN loan_applications a ON a.client_id = c.id
      WHERE a.channel = 'mobile_app'
      GROUP BY c.id) t;
-- Правильно — условие переносим в ON:
SELECT count(*) AS rows_right
FROM (SELECT c.id, count(a.id) AS mobile_apps
      FROM clients c
      LEFT JOIN loan_applications a ON a.client_id = c.id AND a.channel = 'mobile_app'
      GROUP BY c.id) t;

-- 6. Ловушка размножения строк: сумма выдач и сумма платежей по клиенту.
-- Неправильно: каждая строка кредита умножается на число платежей → сумма выдач раздувается.
SELECT a.client_id, sum(l.principal) AS issued_wrong, sum(p.amount) AS paid
FROM loans l
JOIN loan_applications a ON a.id = l.application_id
LEFT JOIN payments p     ON p.loan_id = l.id
GROUP BY a.client_id
ORDER BY a.client_id
LIMIT 5;
-- Правильно: сначала агрегируем платежи до уровня кредита, потом соединяем.
SELECT a.client_id, sum(l.principal) AS issued, sum(coalesce(pp.paid, 0)) AS paid
FROM loans l
JOIN loan_applications a ON a.id = l.application_id
LEFT JOIN (SELECT loan_id, sum(amount) AS paid FROM payments GROUP BY loan_id) pp
       ON pp.loan_id = l.id
GROUP BY a.client_id
ORDER BY a.client_id
LIMIT 5;

-- 7. Просроченные платежи: строки графика без оплаты со сроком в прошлом
SELECT l.contract_number, s.installment_no, s.due_date, s.total_due,
       sandbox_today() - s.due_date AS days_overdue
FROM repayment_schedule s
JOIN loans l          ON l.id = s.loan_id
LEFT JOIN payments p  ON p.loan_id = s.loan_id AND p.installment_no = s.installment_no
WHERE p.id IS NULL
  AND s.due_date < sandbox_today()
ORDER BY days_overdue DESC
LIMIT 20;

-- 8. Self-join: сколько часов заняло решение по заявке (из истории статусов)
SELECT h_new.application_id,
       h_dec.to_status AS decision,
       round(extract(epoch FROM h_dec.changed_at - h_new.changed_at) / 3600, 1) AS hours_to_decision
FROM application_status_history h_new
JOIN application_status_history h_dec
  ON h_dec.application_id = h_new.application_id
 AND h_dec.from_status = 'scoring'
WHERE h_new.to_status = 'new'
ORDER BY hours_to_decision DESC
LIMIT 10;

-- 9. FULL JOIN: сравнение заявок по продуктам за два года (продукт мог быть только в одном году)
SELECT coalesce(y25.product_id, y26.product_id) AS product_id,
       coalesce(y25.cnt, 0) AS apps_2025,
       coalesce(y26.cnt, 0) AS apps_2026
FROM (SELECT product_id, count(*) AS cnt FROM loan_applications
      WHERE created_at >= timestamptz '2025-01-01 00:00+05' AND created_at < timestamptz '2026-01-01 00:00+05'
      GROUP BY product_id) y25
FULL JOIN (SELECT product_id, count(*) AS cnt FROM loan_applications
           WHERE created_at >= timestamptz '2026-01-01 00:00+05'
           GROUP BY product_id) y26
       ON y26.product_id = y25.product_id
ORDER BY 1;

-- 10. CROSS JOIN: матрица «регион × продукт» с нулями там, где заявок не было
SELECT r.name AS region, p.code AS product, count(a.id) AS applications
FROM regions r
CROSS JOIN loan_products p
LEFT JOIN branches b          ON b.region_id = r.id
LEFT JOIN loan_applications a ON a.branch_id = b.id AND a.product_id = p.id
GROUP BY r.name, p.code
ORDER BY r.name, p.code;

-- 11. Последний платёж по каждому кредиту (LATERAL)
SELECT l.contract_number, lp.paid_at, lp.amount
FROM loans l
LEFT JOIN LATERAL (
    SELECT p.paid_at, p.amount
    FROM payments p
    WHERE p.loan_id = l.id
    ORDER BY p.paid_at DESC
    LIMIT 1
) lp ON true
ORDER BY l.id
LIMIT 20;

-- 12. Портфель по регионам: остаток основного долга по живым кредитам
SELECT r.name AS region,
       count(DISTINCT l.id) AS loans,
       sum(s.principal_due) FILTER (WHERE p.id IS NULL) AS outstanding_principal
FROM loans l
JOIN loan_applications a ON a.id = l.application_id
JOIN clients c           ON c.id = a.client_id
JOIN regions r           ON r.id = c.region_id
JOIN repayment_schedule s ON s.loan_id = l.id
LEFT JOIN payments p     ON p.loan_id = s.loan_id AND p.installment_no = s.installment_no
WHERE l.status IN ('active', 'overdue')
GROUP BY r.name
ORDER BY outstanding_principal DESC;

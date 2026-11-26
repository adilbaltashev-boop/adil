-- Урок 05. DBeaver и базовый SQL — решения.
-- Выполнять по одному запросу: поставь курсор внутрь запроса и нажми Ctrl+Enter (⌘+Enter).
SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)

-- 1. Все продукты по возрастанию ставки
SELECT code, name, annual_rate, min_amount, max_amount
FROM loan_products
ORDER BY annual_rate;

-- 2. ИП с ежемесячным доходом больше 700 000 ₸, самые богатые сверху
SELECT last_name, first_name, monthly_income
FROM clients
WHERE client_type = 'entrepreneur'
  AND monthly_income > 700000
ORDER BY monthly_income DESC;

-- 3. Сколько заявок в каждом статусе
SELECT status, count(*) AS applications
FROM loan_applications
GROUP BY status
ORDER BY applications DESC;

-- 4. Средняя, минимальная и максимальная сумма заявки по каналам
SELECT channel,
       count(*)                        AS applications,
       round(avg(requested_amount))    AS avg_amount,
       min(requested_amount)           AS min_amount,
       max(requested_amount)           AS max_amount
FROM loan_applications
GROUP BY channel;

-- 5. Заявки за октябрь 2026 года.
-- Диапазон «>= начала и < начала следующего месяца» — так работает индекс и не теряется последний день.
SELECT id, client_id, requested_amount, status, created_at
FROM loan_applications
WHERE created_at >= timestamptz '2026-10-01 00:00+05'
  AND created_at <  timestamptz '2026-11-01 00:00+05'
ORDER BY created_at;

-- 6. Доля отказов по каналам, %
SELECT channel,
       count(*) FILTER (WHERE status = 'rejected')                           AS rejected,
       count(*) FILTER (WHERE status IN ('rejected', 'approved', 'issued'))  AS decided,
       round(100.0 * count(*) FILTER (WHERE status = 'rejected')
             / count(*) FILTER (WHERE status IN ('rejected', 'approved', 'issued')), 1) AS reject_rate_pct
FROM loan_applications
GROUP BY channel;

-- 7. Клиенты с фамилией, начинающейся на «Ахмет»
SELECT id, last_name, first_name, middle_name
FROM clients
WHERE last_name LIKE 'Ахмет%';

-- 8. Клиенты без отчества
SELECT count(*) AS without_middle_name
FROM clients
WHERE middle_name IS NULL;          -- «= NULL» всегда даёт пустой результат

-- 9. Десять крупнейших кредитов
SELECT contract_number, principal, term_months, issued_on, status
FROM loans
ORDER BY principal DESC
LIMIT 10;

-- 10. Выдачи 2025 года по месяцам: количество и объём
SELECT date_trunc('month', issued_on)::date AS month,
       count(*)                             AS loans,
       sum(principal)                       AS volume
FROM loans
WHERE issued_on >= date '2025-01-01' AND issued_on < date '2026-01-01'
GROUP BY 1
ORDER BY 1;

-- 11. Клиенты, подавшие больше трёх заявок
SELECT client_id, count(*) AS applications
FROM loan_applications
GROUP BY client_id
HAVING count(*) > 3
ORDER BY applications DESC;

-- 12. Сколько клиентов младше 25 лет на «сегодня» песочницы
SELECT count(*) AS under_25
FROM clients
WHERE age(sandbox_today(), birth_date) < interval '25 years';

-- 13. Платежи по каналам: количество и сумма
SELECT channel, count(*) AS payments, sum(amount) AS total
FROM payments
GROUP BY channel
ORDER BY total DESC;

-- 14. Сегменты клиентов по доходу
SELECT CASE
           WHEN monthly_income < 200000  THEN '1. до 200 тыс.'
           WHEN monthly_income < 500000  THEN '2. 200–500 тыс.'
           WHEN monthly_income < 1000000 THEN '3. 500 тыс. – 1 млн'
           ELSE                               '4. от 1 млн'
       END AS income_segment,
       count(*) AS clients
FROM clients
GROUP BY 1
ORDER BY 1;

-- 15. Какие цели кредита встречаются и сколько раз
SELECT purpose, count(*) AS applications
FROM loan_applications
GROUP BY purpose
ORDER BY applications DESC;

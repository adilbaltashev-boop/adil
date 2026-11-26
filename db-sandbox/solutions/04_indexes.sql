-- Урок 04. Индексы — практика.
-- Выполняй блоками по порядку и сравнивай планы «до» и «после».
-- EXPLAIN ANALYZE реально выполняет запрос — с INSERT/UPDATE/DELETE используй его внутри BEGIN … ROLLBACK.
SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)

-- ---------------------------------------------------------------------
-- 0. Готовим большую таблицу: ~1 млн платежей (≈ 13 копий реальных).
--    Занимает 10–60 секунд и ~120 МБ. Удалить в конце: DROP TABLE payments_big;
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS payments_big;
CREATE TABLE payments_big AS
SELECT row_number() OVER () AS id,
       p.loan_id + 10000 * (g - 1) AS loan_id,   -- «другие» кредиты, чтобы данные не повторялись
       p.installment_no, p.paid_at, p.amount, p.channel
FROM payments p
CROSS JOIN generate_series(1, 13) AS g;
ANALYZE payments_big;

SELECT pg_size_pretty(pg_relation_size('payments_big')) AS table_size,
       (SELECT count(*) FROM payments_big)               AS rows;

-- ---------------------------------------------------------------------
-- 1. Поиск платежей одного кредита
-- ---------------------------------------------------------------------
-- ДО: Seq Scan — читается вся таблица
EXPLAIN ANALYZE SELECT * FROM payments_big WHERE loan_id = 1234;

CREATE INDEX ix_payments_big_loan ON payments_big (loan_id);

-- ПОСЛЕ: Index Scan / Bitmap Index Scan — сравни «Execution Time»
EXPLAIN ANALYZE SELECT * FROM payments_big WHERE loan_id = 1234;

-- ---------------------------------------------------------------------
-- 2. Поиск клиента по фамилии: равенство, префикс, без учёта регистра
-- ---------------------------------------------------------------------
EXPLAIN ANALYZE SELECT * FROM clients WHERE last_name = 'Ахметова';

CREATE INDEX ix_clients_last_name ON clients (last_name);
EXPLAIN ANALYZE SELECT * FROM clients WHERE last_name = 'Ахметова';     -- индекс работает

-- Префиксный LIKE обычным индексом не ускоряется, если сортировка базы не «C».
-- Нужен класс операторов text_pattern_ops:
EXPLAIN ANALYZE SELECT * FROM clients WHERE last_name LIKE 'Ахмет%';
CREATE INDEX ix_clients_last_name_pattern ON clients (last_name text_pattern_ops);
EXPLAIN ANALYZE SELECT * FROM clients WHERE last_name LIKE 'Ахмет%';

-- Поиск без учёта регистра — индекс по выражению; в запросе должно быть то же выражение
CREATE INDEX ix_clients_last_name_lower ON clients (lower(last_name));
EXPLAIN ANALYZE SELECT * FROM clients WHERE lower(last_name) = lower('АХМЕТОВА');

-- ---------------------------------------------------------------------
-- 3. Составной индекс: очередь новых заявок по времени.
--    Порядок колонок важен: сначала колонка из «=», потом из диапазона/сортировки.
-- ---------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT id, client_id, created_at FROM loan_applications
WHERE status = 'scoring' ORDER BY created_at LIMIT 20;

CREATE INDEX ix_applications_status_created ON loan_applications (status, created_at);

EXPLAIN ANALYZE
SELECT id, client_id, created_at FROM loan_applications
WHERE status = 'scoring' ORDER BY created_at LIMIT 20;

-- Обратный порядок колонок: для этого запроса хуже — индекс отсортирован по времени,
-- и строки со статусом 'scoring' приходится выискивать среди всех заявок
DROP INDEX ix_applications_status_created;
CREATE INDEX ix_applications_created_status ON loan_applications (created_at, status);
EXPLAIN ANALYZE
SELECT id, client_id, created_at FROM loan_applications
WHERE status = 'scoring' ORDER BY created_at LIMIT 20;
DROP INDEX ix_applications_created_status;
CREATE INDEX ix_applications_status_created ON loan_applications (status, created_at);

-- Запрос только по created_at не может точечно войти в индекс (status, created_at): created_at второй.
-- До PostgreSQL 17 он в лучшем случае читает индекс целиком; в PG18 появился skip scan, который это частично обходит.
EXPLAIN SELECT count(*) FROM loan_applications WHERE created_at >= timestamptz '2026-11-01 00:00+05';

-- ---------------------------------------------------------------------
-- 4. Частичный индекс: проблемные кредиты (их мало, а ищут их часто)
-- ---------------------------------------------------------------------
CREATE INDEX ix_loans_problem ON loans (issued_on) WHERE status IN ('overdue', 'written_off');
EXPLAIN ANALYZE SELECT * FROM loans WHERE status IN ('overdue', 'written_off') ORDER BY issued_on;
CREATE INDEX ix_loans_issued_full ON loans (issued_on);
SELECT pg_size_pretty(pg_relation_size('ix_loans_problem'))    AS partial_index_size,
       pg_size_pretty(pg_relation_size('ix_loans_issued_full')) AS full_index_size;
DROP INDEX ix_loans_issued_full;

-- ---------------------------------------------------------------------
-- 5. Когда индекс НЕ помогает: низкая селективность.
--    channel принимает 4 значения — четверть таблицы проще прочитать целиком.
-- ---------------------------------------------------------------------
CREATE INDEX ix_payments_big_channel ON payments_big (channel);
ANALYZE payments_big;
EXPLAIN ANALYZE SELECT count(*) FROM payments_big WHERE channel = 'mobile_app';  -- скорее всего Seq Scan
DROP INDEX ix_payments_big_channel;

-- ---------------------------------------------------------------------
-- 6. Цена лишних индексов: вставка 200 000 строк без индексов и с шестью
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ins_test;
CREATE TABLE ins_test (LIKE payments_big);

DO $$
DECLARE t0 timestamptz; ms_plain numeric; ms_indexed numeric;
BEGIN
    t0 := clock_timestamp();
    INSERT INTO ins_test SELECT * FROM payments_big LIMIT 200000;
    ms_plain := extract(epoch FROM clock_timestamp() - t0) * 1000;
    TRUNCATE ins_test;
    CREATE INDEX ON ins_test (loan_id);
    CREATE INDEX ON ins_test (paid_at);
    CREATE INDEX ON ins_test (amount);
    CREATE INDEX ON ins_test (channel);
    CREATE INDEX ON ins_test (loan_id, installment_no);
    CREATE INDEX ON ins_test (id);
    t0 := clock_timestamp();
    INSERT INTO ins_test SELECT * FROM payments_big LIMIT 200000;
    ms_indexed := extract(epoch FROM clock_timestamp() - t0) * 1000;
    RAISE NOTICE 'Вставка 200 000 строк: без индексов % мс, с 6 индексами % мс (в % раза медленнее)',
        round(ms_plain), round(ms_indexed), round(ms_indexed / nullif(ms_plain, 0), 1);
END $$;

SELECT pg_size_pretty(pg_relation_size('ins_test')) AS table_size,
       pg_size_pretty(pg_indexes_size('ins_test'))  AS indexes_size;

-- ---------------------------------------------------------------------
-- 7. Какие индексы ни разу не использовались (кандидаты на удаление)
-- ---------------------------------------------------------------------
SELECT relname AS table_name, indexrelname AS index_name, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'credit'
ORDER BY idx_scan, pg_relation_size(indexrelid) DESC;

-- ---------------------------------------------------------------------
-- Уборка: вернуть песочницу к исходному состоянию
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ins_test;
DROP TABLE IF EXISTS payments_big;
DROP INDEX IF EXISTS ix_clients_last_name, ix_clients_last_name_pattern, ix_clients_last_name_lower,
                     ix_applications_status_created, ix_loans_problem;

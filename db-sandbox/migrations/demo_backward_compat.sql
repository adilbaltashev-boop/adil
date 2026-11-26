-- Демонстрация обратной совместимости после V003 (до V004).
-- Всё внутри транзакции с откатом — данные не меняются (сдвигается только счётчик id заявок).
SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)
BEGIN;

-- «Старое» приложение: пишет только текст цели
INSERT INTO loan_applications (client_id, product_id, branch_id, channel, requested_amount,
                               requested_term_months, purpose, status, created_at)
VALUES (1, 1, 1, 'mobile_app', 500000, 12, 'Лечение', 'new', now())
RETURNING id, purpose, purpose_code;

-- «Новое» приложение: пишет только код
INSERT INTO loan_applications (client_id, product_id, branch_id, channel, requested_amount,
                               requested_term_months, purpose_code, status, created_at)
VALUES (1, 1, 1, 'mobile_app', 700000, 12, 'EDUCATION', 'new', now())
RETURNING id, purpose, purpose_code;

-- Существующая заявка: «новая» версия меняет код — текст должен подтянуться
UPDATE loan_applications SET purpose_code = 'EDUCATION' WHERE id = 1
RETURNING id, purpose, purpose_code;

ROLLBACK;
-- Если какой-то запрос выше упал с ошибкой, DBeaver остановит скрипт до ROLLBACK.
-- Тогда выполни ROLLBACK; вручную — иначе все следующие запросы будут падать
-- с ошибкой «current transaction is aborted».

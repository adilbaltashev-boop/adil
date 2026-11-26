-- Демонстрация обратной совместимости после V003 (до V004).
-- Всё внутри транзакции с откатом — данные песочницы не меняются.
SET search_path TO credit;
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

ROLLBACK;

-- =====================================================================
-- Проверка, что песочница загрузилась правильно.
-- Если всё в порядке — выполнится молча и вернёт строку «OK».
-- Если нет — остановится с ошибкой «ПРОВЕРКА НЕ ПРОЙДЕНА: ...».
-- =====================================================================

SET search_path TO credit;
SET TIME ZONE 'Asia/Almaty';  -- данные и даты не должны зависеть от пояса клиента (DBeaver берёт пояс компьютера)

DO $$
DECLARE
    n bigint;
BEGIN
    -- 1. Объёмы данных
    SELECT count(*) INTO n FROM clients;
    IF n < 4900 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: клиентов % (ожидалось ~5000)', n; END IF;
    SELECT count(*) INTO n FROM loan_applications;
    IF n <> 8000 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: заявок % (ожидалось 8000)', n; END IF;
    SELECT count(*) INTO n FROM loans;
    IF n < 5000 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: кредитов % (ожидалось > 5000)', n; END IF;
    -- 2. У каждой выданной заявки есть кредит, и наоборот
    SELECT count(*) INTO n
    FROM loan_applications a LEFT JOIN loans l ON l.application_id = a.id
    WHERE a.status = 'issued' AND l.id IS NULL;
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % выданных заявок без кредита', n; END IF;
    SELECT count(*) INTO n
    FROM loans l JOIN loan_applications a ON a.id = l.application_id
    WHERE a.status <> 'issued';
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % кредитов по невыданным заявкам', n; END IF;
    -- 3. Сумма основного долга по графику равна сумме выдачи
    SELECT count(*) INTO n
    FROM loans l JOIN (SELECT loan_id, sum(principal_due) AS s, count(*) AS c
                       FROM repayment_schedule GROUP BY loan_id) g ON g.loan_id = l.id
    WHERE g.s <> l.principal OR g.c <> l.term_months;
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: у % кредитов график не сходится с суммой', n; END IF;
    -- 4. Платежи не раньше выдачи и не позже «сегодня»
    SELECT count(*) INTO n
    FROM payments p JOIN loans l ON l.id = p.loan_id
    WHERE p.paid_at::date < l.issued_on OR p.paid_at::date > sandbox_today();
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % платежей вне срока жизни кредита', n; END IF;
    -- 5. Не больше одного платежа на строку графика
    SELECT count(*) INTO n
    FROM (SELECT 1 FROM payments GROUP BY loan_id, installment_no HAVING count(*) > 1) d;
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % строк графика оплачены дважды', n; END IF;
    -- 6. Статус «просрочен» стоит только там, где есть неоплаченный прошедший платёж
    SELECT count(*) INTO n
    FROM loans l
    WHERE l.status IN ('overdue', 'written_off')
      AND NOT EXISTS (
          SELECT 1 FROM repayment_schedule s
          LEFT JOIN payments p ON p.loan_id = s.loan_id AND p.installment_no = s.installment_no
          WHERE s.loan_id = l.id AND s.due_date < sandbox_today() AND p.id IS NULL);
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % кредитов в просрочке без долга', n; END IF;
    -- 6б. «Закрыт» — только когда оплачены все строки графика
    SELECT count(*) INTO n
    FROM loans l
    WHERE l.status = 'closed'
      AND EXISTS (
          SELECT 1 FROM repayment_schedule s
          LEFT JOIN payments p ON p.loan_id = s.loan_id AND p.installment_no = s.installment_no
          WHERE s.loan_id = l.id AND p.id IS NULL);
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % закрытых кредитов с неоплаченным графиком', n; END IF;
    -- 6в. Сумма кредита не ниже минимума продукта
    SELECT count(*) INTO n
    FROM loans l
    JOIN loan_applications a ON a.id = l.application_id
    JOIN loan_products p ON p.id = a.product_id
    WHERE l.principal < p.min_amount OR l.principal > a.requested_amount;
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % кредитов с суммой вне правил', n; END IF;
    -- 7. Продукт подходит типу клиента; «женский» продукт — только женщинам
    SELECT count(*) INTO n
    FROM loan_applications a
    JOIN clients c ON c.id = a.client_id
    JOIN loan_products p ON p.id = a.product_id
    WHERE p.client_type <> c.client_type OR (p.only_for_women AND c.gender <> 'F');
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % заявок с неподходящим продуктом', n; END IF;
    -- 8. Сумма и срок заявки в пределах продукта
    SELECT count(*) INTO n
    FROM loan_applications a JOIN loan_products p ON p.id = a.product_id
    WHERE a.requested_amount NOT BETWEEN p.min_amount AND p.max_amount
       OR a.requested_term_months NOT BETWEEN p.min_term_months AND p.max_term_months;
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % заявок вне параметров продукта', n; END IF;
    -- 9. Все кредиты по агропродукту с залогом
    SELECT count(*) INTO n
    FROM loans l
    JOIN loan_applications a ON a.id = l.application_id
    JOIN loan_products p ON p.id = a.product_id
    WHERE p.requires_collateral AND NOT EXISTS (SELECT 1 FROM collaterals c WHERE c.loan_id = l.id);
    IF n > 0 THEN RAISE EXCEPTION 'ПРОВЕРКА НЕ ПРОЙДЕНА: % залоговых кредитов без залога', n; END IF;
END $$;

SELECT 'OK' AS result,
       (SELECT count(*) FROM clients)            AS clients,
       (SELECT count(*) FROM loan_applications)  AS applications,
       (SELECT count(*) FROM loans)              AS loans,
       (SELECT count(*) FROM payments)           AS payments;

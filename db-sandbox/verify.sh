#!/usr/bin/env bash
# Полная самопроверка песочницы: заливает схему и данные, прогоняет проверки,
# все решения и миграции туда-обратно. Нужен psql и пустая (или учебная) база.
#
# Параметры подключения берутся из стандартных переменных PostgreSQL:
#   PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD (пароль — только через переменную, не в коде).
# Пример для Postgres.app:  PGDATABASE=postgres ./verify.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"

run() { psql -X -q -v ON_ERROR_STOP=1 -f "$1" > /dev/null; echo "  ok  $1"; }

echo "1. Схема и данные"
run sql/01_schema.sql
run sql/02_seed.sql
run sql/03_checks.sql

echo "2. Решения уроков"
for f in solutions/05_sql_basics.sql solutions/07_json.sql solutions/08_joins.sql \
         solutions/04_indexes.sql solutions/03_distributed.sql; do
    run "$f"
done

echo "3. Миграции: накат и откат"
run migrations/V002__loans_penalty_rate.sql
run migrations/V003__purpose_code_expand.sql
run migrations/demo_backward_compat.sql
run migrations/V004__purpose_code_contract.sql
run migrations/U004__purpose_code_contract.sql
run migrations/U003__purpose_code_expand.sql
run migrations/U002__loans_penalty_rate.sql

echo "4. Песочница после всех уроков в исходном состоянии"
run sql/03_checks.sql
psql -X -q -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS svc_client, svc_origination, svc_loan, svc_payment CASCADE;" > /dev/null

echo "Всё прошло."

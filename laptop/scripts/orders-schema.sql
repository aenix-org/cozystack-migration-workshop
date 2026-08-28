-- Схема orders для managed Postgres (таблица + история-сид).
--
-- Роль `orders` и БД `orders` создаёт Postgres-chart (Postgres CR), поэтому здесь
-- НЕТ CREATE USER / CREATE DATABASE — только таблица и немного истории.
--
-- ВАЖНО (PG 15+): роль orders не может создавать таблицы в схеме public без
-- гранта. Сначала один раз под superuser (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- и только потом накатывать этот файл от роли orders. Без таблицы приложение
-- отвечает 500 на POST /api/orders (health при этом 200 — он проверяет лишь
-- коннект к PG, а не наличие таблицы).
--
-- Запуск (с app-VM или любой машины с доступом к managed PG):
--     PGPASSWORD='<orders-pw>' psql -h postgres-db-rw -U orders -d orders -f orders-schema.sql

CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);

-- немного истории, чтобы список не выглядел пустым на проекторе
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);

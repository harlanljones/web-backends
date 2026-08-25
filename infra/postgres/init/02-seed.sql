-- Copy seed data from pre-generated CSVs. The CSVs are produced by
-- bench/seed/seed.py and written into /seed by the seeder container (see
-- docker-compose.yml). This script TRUNCATEs first so a re-seed after
-- `down.sh --volumes` is idempotent.
--
-- The file paths in COPY commands are *inside the database container*, which
-- means the seeder has to land the CSVs in the same bind mount the database
-- reads from. The compose file does that by mounting bench/seed/out into both
-- containers at /seed.

\set ON_ERROR_STOP on

TRUNCATE customers RESTART IDENTITY CASCADE;
\copy customers (email, full_name, country) FROM '/seed/customers.csv' (FORMAT csv)

TRUNCATE products RESTART IDENTITY CASCADE;
\copy products (sku, name, description, category_id, price_cents, stock, active) FROM '/seed/products.csv' (FORMAT csv)

TRUNCATE orders, order_items, inventory_ledger CASCADE;
\copy orders (customer_id, status, total_cents, idempotency_key) FROM '/seed/orders.csv' (FORMAT csv)
\copy order_items (order_id, product_id, quantity, unit_price_cents) FROM '/seed/order_items.csv' (FORMAT csv)
\copy inventory_ledger (product_id, order_id, delta) FROM '/seed/inventory_ledger.csv' (FORMAT csv)

ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
ANALYZE inventory_ledger;

-- Reset pg_stat_statements so the first trial's counters are not polluted by
-- the seed. The framework's first query will reset this again at the start of
-- each trial.
SELECT pg_stat_statements_reset();

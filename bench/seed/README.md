# Seed generator

Deterministic CSV generation for the benchmark database. The database's
`infra/postgres/init/02-seed.sql` `COPY`s from these CSVs; generating them
outside SQL keeps the `COPY` simple and lets the same script emit smaller seeds
for smoke tests.

## Usage

```bash
# Read sizes from the environment (what the Compose seeder uses)
SEED_PRODUCTS=1000 SEED_CUSTOMERS=500 SEED_ORDERS=2000 \
  python3 bench/seed/seed.py out/ -

# Or from a JSON file
python3 bench/seed/seed.py out/ seed.json
```

`seed.json` shape (all keys optional):

```json
{ "products": 100000, "customers": 50000, "orders": 250000, "items_per_order": 2 }
```

## Output files

| File | Contents |
| --- | --- |
| `customers.csv` | email, name, country |
| `products.csv` | sku, name, description, category_id, price_cents, stock, active |
| `orders.csv` | the `orders` rows (including the unique `idempotency_key`) |
| `order_items.csv` | the line items for each order |
| `inventory_ledger.csv` | the per-order stock decrements |

## Determinism

Each table is generated from its own seeded `random.Random(seed)` instance, so
the same sizes always produce byte-identical CSVs. This is what makes a trial
reproducible: every framework reads the same data.

## Why the seed is sized the way it is

See `docs/benchmark/database.md` — the short version is that the catalog is
large enough that an ORM's plan-cache and serialization cost dominate a
saturated read, and the order history is large enough that the dashboard
aggregate cannot live entirely in the page cache.

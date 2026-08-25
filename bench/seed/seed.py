#!/usr/bin/env python3
"""Generate CSV files for the benchmark seed in deterministic form.

Output files are written to the directory given as the first argument. The
companion SQL files in 02-seed.sql COPY from these. Generating them outside of
SQL keeps the COPY simple and lets the same scripts produce smaller seeds for
unit tests (bench/seed/small).

Sizes match the default SEED_* environment variables; pass overrides as a
JSON object on the command line if you need a different size.
"""
import csv
import json
import os
import random
import sys
import uuid


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: seed.py OUTDIR SEEDJSON", file=sys.stderr)
        return 2

    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)

    # Two ways to specify sizes:
    #   1. A path to a JSON file (e.g. /tmp/seed.json)
    #   2. The literal "-" meaning "read from environment variables"
    # The Docker entrypoint for the seeder container prefers (2) because
    # Compose expands ${SEED_PRODUCTS:-...} into the environment, not into
    # the command string.
    arg = sys.argv[2]
    if arg == "-":
        n_products = int(os.environ.get("SEED_PRODUCTS", 100_000))
        n_customers = int(os.environ.get("SEED_CUSTOMERS", 50_000))
        n_orders = int(os.environ.get("SEED_ORDERS", 250_000))
        items_per_order = int(os.environ.get("SEED_ITEMS_PER_ORDER", 2))
    else:
        with open(arg) as f:
            seed = json.load(f)
        n_products = int(seed.get("products", 100_000))
        n_customers = int(seed.get("customers", 50_000))
        n_orders = int(seed.get("orders", 250_000))
        items_per_order = int(seed.get("items_per_order", 2))
    countries = "US,CA,GB,DE,FR,JP,BR,AU,IN,MX".split(",")
    statuses = ["pending", "paid", "shipped", "cancelled"]
    categories = [
        "Electronics", "Books", "Clothing", "Home", "Toys",
        "Grocery", "Sports", "Beauty", "Tools", "Garden",
    ]

    # Customers ----------------------------------------------------------------
    with open(os.path.join(outdir, "customers.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        rng = random.Random(42)
        for i in range(1, n_customers + 1):
            w.writerow([
                f"user{i}@example.test",
                f"User {i:08d}",
                countries[rng.randrange(len(countries))],
            ])

    # Products ----------------------------------------------------------------
    with open(os.path.join(outdir, "products.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        rng = random.Random(43)
        for i in range(1, n_products + 1):
            cat = rng.randrange(1, len(categories) + 1)
            price = 100 + rng.randrange(99_900)
            stock = rng.randrange(1_000)
            active = "t" if rng.random() > 0.05 else "f"
            w.writerow([
                f"SKU-{i:08d}",
                f"Product {i} {categories[cat - 1]}",
                (f"Long description for product {i} in the {categories[cat-1]} "
                 "category. It is a high quality item suitable for daily use "
                 "with features that are commonly desired by customers."),
                cat, price, stock, active,
            ])

    # Orders, items, ledger. The idempotency_key column is unique, so re-seeds
    # of a database that already has rows would fail the COPY. Always TRUNCATE
    # upstream; the SQL file does that explicitly.
    with open(os.path.join(outdir, "orders.csv"), "w", newline="") as f, \
         open(os.path.join(outdir, "order_items.csv"), "w", newline="") as g, \
         open(os.path.join(outdir, "inventory_ledger.csv"), "w", newline="") as h:
        wo, wi, wl = (csv.writer(x, lineterminator="\n") for x in (f, g, h))
        rng = random.Random(44)
        rng_items = random.Random(45)
        rng_ledger = random.Random(46)
        for i in range(1, n_orders + 1):
            cust = rng.randrange(1, n_customers + 1)
            status = statuses[rng.randrange(len(statuses))]
            total = 1_000 + rng.randrange(50_000)
            wo.writerow([cust, status, total, str(uuid.uuid4())])
            for j in range(items_per_order):
                product = rng_items.randrange(1, n_products + 1)
                qty = 1 + rng_items.randrange(3)
                price = 100 + rng_items.randrange(99_900)
                wi.writerow([i, product, qty, price])
                product2 = rng_ledger.randrange(1, n_products + 1)
                wl.writerow([product2, i, -(1 + rng_ledger.randrange(3))])

    return 0


if __name__ == "__main__":
    sys.exit(main())

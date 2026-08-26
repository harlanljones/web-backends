package com.bench.service;

import com.bench.error.InsufficientStockException;
import com.bench.error.UnknownProductException;
import com.bench.model.Models;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * The transactional write workload.
 *
 * <p>Runs in one {@code @Transactional} unit (with Hikari's default READ
 * COMMITTED isolation). It locks product rows in sorted id order so two
 * concurrent requests touching overlapping product sets cannot deadlock,
 * then checks stock, computes the total, and writes orders / order_items /
 * inventory_ledger while decrementing stock. The idempotency insert uses the
 * ordered key as a unique constraint; a conflict means "replay", so the
 * original order is read and returned.
 */
@Service
public class OrderService {

    private final JdbcTemplate jdbc;

    public OrderService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional
    public Models.Order createOrder(UUID idemKey, Models.OrderRequest req) {
        long customerId = req.customerId();
        List<Models.OrderItem> items = req.items();

        // Distinct product ids, sorted, so the row locks are acquired in a
        // stable order (good for N <= 20 items, so no sort overhead matters).
        long[] productIds = items.stream()
            .mapToLong(Models.OrderItem::productId)
            .distinct()
            .sorted()
            .toArray();

        // Lock each product row and capture price + stock.
        Map<Long, int[]> locked = new HashMap<>();
        for (long pid : productIds) {
            List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT price_cents, stock FROM products WHERE id = ? FOR UPDATE", pid);
            if (rows.isEmpty()) {
                throw new UnknownProductException(pid);
            }
            Map<String, Object> row = rows.get(0);
            locked.put(pid, new int[]{
                ((Number) row.get("price_cents")).intValue(),
                ((Number) row.get("stock")).intValue()});
        }

        // Check stock and compute the total. Total stays small under the
        // contract's bounds (price <= ~100k * quantity <= 1000 * <= 20 items),
        // so a long accumulator is plenty and the column integer is safe.
        long total = 0;
        for (Models.OrderItem item : items) {
            int[] p = locked.get(item.productId());
            if (p == null) {
                throw new UnknownProductException(item.productId());
            }
            if (p[1] < item.quantity()) {
                throw new InsufficientStockException(item.productId(), p[1], item.quantity());
            }
            total += (long) p[0] * item.quantity();
        }
        int totalCents = (int) total;

        // Insert the order. The idempotency_key column is UNIQUE, so a repeat
        // conflicts and the RETURNING clause yields no row -> replay.
        Long orderId = jdbc.query(
            "INSERT INTO orders (customer_id, status, total_cents, idempotency_key) "
            + "VALUES (?, 'pending', ?, ?) "
            + "ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
            ps -> {
                ps.setLong(1, customerId);
                ps.setInt(2, totalCents);
                ps.setObject(3, idemKey);
            },
            rs -> rs.next() ? rs.getLong(1) : null);

        if (orderId == null) {
            // Replay. Nothing was written, so the transaction commits as a
            // no-op and the committed original is returned.
            return readExistingOrder(idemKey);
        }

        // Items + ledger rows + stock decrement. The product rows are already
        // locked, so the decrement is the only write and is race-free.
        for (Models.OrderItem item : items) {
            int priceCents = locked.get(item.productId())[0];
            int qty = item.quantity();

            jdbc.update(
                "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) "
                + "VALUES (?, ?, ?, ?)",
                orderId, item.productId(), qty, priceCents);

            jdbc.update(
                "INSERT INTO inventory_ledger (product_id, order_id, delta) VALUES (?, ?, ?)",
                item.productId(), orderId, -qty);

            jdbc.update(
                "UPDATE products SET stock = stock - ?, updated_at = now() WHERE id = ?",
                qty, item.productId());
        }

        List<Models.OrderItemResponse> respItems = new ArrayList<>(items.size());
        for (Models.OrderItem item : items) {
            respItems.add(new Models.OrderItemResponse(
                item.productId(), item.quantity(), locked.get(item.productId())[0]));
        }
        return new Models.Order(orderId, customerId, "pending", totalCents, respItems);
    }

    private Models.Order readExistingOrder(UUID idemKey) {
        Map<String, Object> orderRow;
        try {
            orderRow = jdbc.queryForMap(
                "SELECT id, customer_id, status::text, total_cents "
                + "FROM orders WHERE idempotency_key = ?", idemKey);
        } catch (EmptyResultDataAccessException e) {
            throw new IllegalStateException("idempotency conflict but no order row", e);
        }

        long id = ((Number) orderRow.get("id")).longValue();
        long customerId = ((Number) orderRow.get("customer_id")).longValue();
        String status = (String) orderRow.get("status");
        int totalCents = ((Number) orderRow.get("total_cents")).intValue();

        List<Models.OrderItemResponse> items = jdbc.query(
            "SELECT product_id, quantity, unit_price_cents "
            + "FROM order_items WHERE order_id = ?",
            (rs, n) -> new Models.OrderItemResponse(
                rs.getLong("product_id"),
                rs.getInt("quantity"),
                rs.getInt("unit_price_cents")),
            id);

        return new Models.Order(id, customerId, status, totalCents, items);
    }
}

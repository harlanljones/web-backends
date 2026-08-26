package com.bench.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.JdbcTemplate;

@RestController
public class DashboardController {

    private static final String DASHBOARD_AGG =
        "SELECT c.id, c.name, COUNT(o.id) AS order_count, "
        + "COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents "
        + "FROM categories c "
        + "LEFT JOIN orders o "
        + "  ON o.status IN ('paid', 'shipped') "
        + "  AND o.created_at >= now() - (?::int || ' days')::interval "
        + "  AND EXISTS (SELECT 1 FROM order_items oi JOIN products p ON p.id = oi.product_id "
        + "      WHERE oi.order_id = o.id AND p.category_id = c.id) "
        + "GROUP BY c.id, c.name "
        + "ORDER BY c.id";

    private final JdbcTemplate jdbc;

    public DashboardController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping(value = "/dashboard", produces = "text/html; charset=utf-8")
    public String dashboard(@RequestParam(name = "days", required = false) String days) {
        int daysValue = parseDays(days);

        List<Map<String, Object>> rows = jdbc.queryForList(DASHBOARD_AGG, daysValue);

        StringBuilder b = new StringBuilder();
        b.append("<!doctype html><html><head><title>Bench dashboard</title></head><body>");
        b.append("<h1>Bench dashboard</h1>");
        b.append("<table border=1><thead><tr><th>Category</th><th>Orders</th><th>Total ($)</th></tr></thead><tbody>");
        for (Map<String, Object> r : rows) {
            String name = String.valueOf(r.get("name"));
            long orderCount = ((Number) r.get("order_count")).longValue();
            long totalCents = ((Number) r.get("total_cents")).longValue();
            b.append("<tr><td>").append(htmlEscape(name)).append("</td><td>")
                .append(orderCount).append("</td><td>")
                .append(String.format("%.2f", totalCents / 100.0))
                .append("</td></tr>");
        }
        b.append("</tbody></table></body></html>");
        return b.toString();
    }

    // The contract clamps days to 1..365; an absent or invalid value falls back
    // to 30. This is deliberately permissive (the reference Rust clamps, too).
    private static int parseDays(String raw) {
        if (raw == null || raw.isBlank()) {
            return 30;
        }
        try {
            int n = Integer.parseInt(raw.trim());
            if (n < 1) {
                return 1;
            }
            if (n > 365) {
                return 365;
            }
            return n;
        } catch (NumberFormatException e) {
            return 30;
        }
    }

    private static String htmlEscape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("\"", "&quot;");
    }
}

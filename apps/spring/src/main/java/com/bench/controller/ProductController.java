package com.bench.controller;

import com.bench.error.ProductNotFoundException;
import com.bench.model.Models;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
public class ProductController {

    private static final String PRODUCT_SELECT =
        "SELECT id, sku, name, description, category_id, price_cents, stock, active "
        + "FROM products WHERE id = ?";

    private final JdbcTemplate jdbc;

    public ProductController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping("/products/{id}")
    public Models.Product getProduct(@PathVariable("id") long id) {
        List<Models.Product> rows = jdbc.query(PRODUCT_SELECT, (rs, n) -> new Models.Product(
            rs.getLong("id"),
            rs.getString("sku"),
            rs.getString("name"),
            rs.getString("description"),
            rs.getInt("category_id"),
            rs.getInt("price_cents"),
            rs.getInt("stock"),
            rs.getBoolean("active")), id);
        if (rows.isEmpty()) {
            throw new ProductNotFoundException(id);
        }
        return rows.get(0);
    }
}

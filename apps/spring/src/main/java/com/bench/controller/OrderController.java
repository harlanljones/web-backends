package com.bench.controller;

import com.bench.model.Models;
import com.bench.service.OrderService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping("/orders")
    public ResponseEntity<?> create(
            @RequestHeader(name = "Idempotency-Key", required = false) String idemHeader,
            @RequestBody Models.OrderRequest req) {

        if (idemHeader == null || idemHeader.isBlank()) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(new Models.GeneralError("Idempotency-Key header is required", null));
        }
        UUID idemKey;
        try {
            idemKey = UUID.fromString(idemHeader);
        } catch (IllegalArgumentException e) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(new Models.GeneralError("invalid Idempotency-Key", null));
        }
        if (req.items() == null || req.items().isEmpty()) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(new Models.GeneralError("items must be non-empty", null));
        }

        Models.Order order = orderService.createOrder(idemKey, req);
        return ResponseEntity.status(HttpStatus.CREATED).body(order);
    }
}

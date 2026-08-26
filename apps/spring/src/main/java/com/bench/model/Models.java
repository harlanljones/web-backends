package com.bench.model;

import java.util.List;

/**
 * Request/response bodies for the contract. The Jackson naming strategy is
 * SNAKE_CASE, so {@code customerId} serializes as {@code customer_id} and the
 * incoming {@code customer_id} deserializes into {@code customerId}.
 */
public final class Models {
    private Models() {}

    public record JsonResponse(String service, String version, String time) {}

    public record Product(
            long id,
            String sku,
            String name,
            String description,
            int categoryId,
            int priceCents,
            int stock,
            boolean active) {}

    // -- orders ------------------------------------------------------------

    public record OrderRequest(long customerId, List<OrderItem> items) {}

    public record OrderItem(long productId, int quantity) {}

    public record OrderItemResponse(long productId, int quantity, int unitPriceCents) {}

    public record Order(
            long id,
            long customerId,
            String status,
            int totalCents,
            List<OrderItemResponse> items) {}

    public record GeneralError(String error, java.util.Map<String, Object> details) {}
}

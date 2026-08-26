package com.bench.error;

/** A requested quantity exceeds the locked stock. Mapped to 409 conflict. */
public class InsufficientStockException extends RuntimeException {
    private final long productId;
    private final int available;
    private final int requested;

    public InsufficientStockException(long productId, int available, int requested) {
        super("insufficient stock for product " + productId);
        this.productId = productId;
        this.available = available;
        this.requested = requested;
    }

    public long productId() { return productId; }
    public int available() { return available; }
    public int requested() { return requested; }
}

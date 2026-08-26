package com.bench.error;

/** A referenced product is unknown to the write workload. Mapped to 400. */
public class UnknownProductException extends RuntimeException {
    private final long productId;

    public UnknownProductException(long productId) {
        super("unknown product " + productId);
        this.productId = productId;
    }

    public long productId() { return productId; }
}

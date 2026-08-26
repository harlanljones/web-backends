package com.bench.error;

/** A product id does not exist. Mapped to 404 not-found. */
public class ProductNotFoundException extends RuntimeException {
    public ProductNotFoundException(long id) {
        super("no product with id " + id);
    }
}

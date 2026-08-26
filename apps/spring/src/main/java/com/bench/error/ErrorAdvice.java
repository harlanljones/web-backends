package com.bench.error;

import com.bench.model.Models;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.http.converter.HttpMessageNotReadableException;

import java.util.Map;

/**
 * Maps application exceptions to the contract's error JSON
 * {@code {"error": "...", "details": {...}}}. The {@code details} value is
 * null for the simple errors, which the global NON_NULL inclusion omits.
 */
@RestControllerAdvice
public class ErrorAdvice {

    @ExceptionHandler(ProductNotFoundException.class)
    public ResponseEntity<Models.GeneralError> notFound(ProductNotFoundException e) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
            .body(new Models.GeneralError("not found", null));
    }

    @ExceptionHandler(InsufficientStockException.class)
    public ResponseEntity<Models.GeneralError> conflict(InsufficientStockException e) {
        Map<String, Object> details = Map.of(
            "product_id", e.productId(),
            "available", e.available(),
            "requested", e.requested());
        return ResponseEntity.status(HttpStatus.CONFLICT)
            .body(new Models.GeneralError("insufficient stock", details));
    }

    @ExceptionHandler(UnknownProductException.class)
    public ResponseEntity<Models.GeneralError> unknownProduct(UnknownProductException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
            .body(new Models.GeneralError("unknown product", Map.of("product_id", e.productId())));
    }

    @ExceptionHandler({MethodArgumentTypeMismatchException.class,
                       MissingRequestHeaderException.class})
    public ResponseEntity<Models.GeneralError> badInput(Exception e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
            .body(new Models.GeneralError("bad request", null));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Models.GeneralError> validation(MethodArgumentNotValidException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
            .body(new Models.GeneralError("validation failed", null));
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Models.GeneralError> unreadable(HttpMessageNotReadableException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
            .body(new Models.GeneralError("invalid body", null));
    }

    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Models.GeneralError> db(DataAccessException e) {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
            .body(new Models.GeneralError("internal error", null));
    }
}

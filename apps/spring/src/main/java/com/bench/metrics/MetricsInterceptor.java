package com.bench.metrics;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.lang.NonNull;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.HandlerMapping;

/**
 * Observes every HTTP request into the contracted histogram.
 *
 * <p>Uses Spring's {@code BEST_MATCHING_PATTERN_ATTRIBUTE} (the route pattern,
 * e.g. {@code /products/{id}}) rather than the request URI so the {@code path}
 * label stays the four workload names and never a per-id cardinality blowup.
 */
@Component
public class MetricsInterceptor implements HandlerInterceptor {

    public static final String START_ATTRIBUTE = "bench.metrics.startNanos";

    @Override
    public boolean preHandle(@NonNull HttpServletRequest request,
                             @NonNull HttpServletResponse response,
                             @NonNull Object handler) {
        request.setAttribute(START_ATTRIBUTE, System.nanoTime());
        return true;
    }

    @Override
    public void afterCompletion(@NonNull HttpServletRequest request,
                                @NonNull HttpServletResponse response,
                                @NonNull Object handler,
                                Exception ex) {
        Object start = request.getAttribute(START_ATTRIBUTE);
        if (!(start instanceof Long startNanos)) {
            return;
        }
        double seconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
        Object pattern = request.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
        String route = (pattern != null) ? pattern.toString() : request.getRequestURI();
        String path = workloadName(route);
        MetricsConfig.HTTP_REQUEST_DURATION
            .labels(path, request.getMethod(), Integer.toString(response.getStatus()))
            .observe(seconds);
    }

    private static String workloadName(String route) {
        return switch (route) {
            case "/json" -> "json";
            case "/products/{id}" -> "product_read";
            case "/orders" -> "order_write";
            case "/dashboard" -> "dashboard";
            case "/health", "/metrics" -> "infra";
            default -> "other";
        };
    }
}

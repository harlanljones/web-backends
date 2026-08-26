package com.bench.metrics;

import io.prometheus.client.CollectorRegistry;
import io.prometheus.client.Histogram;
import io.prometheus.client.hotspot.MemoryPoolsExports;
import io.prometheus.client.hotspot.StandardExports;
import jakarta.annotation.PostConstruct;
import org.springframework.context.annotation.Configuration;

/**
 * The contracted latency histogram plus the JVM hotspot collectors.
 *
 * <p>The histogram is named {@code http_request_duration_seconds} so the
 * {@code bench:app:http_request_duration:p99:rate1m} recording rule picks it
 * up without per-framework changes. The {@code path} label is the workload
 * name ({@code json}, {@code product_read}, {@code order_write},
 * {@code dashboard}, {@code infra}), not the URL pattern, so it stays
 * low-cardinality under the load test.
 */
@Configuration
public class MetricsConfig {

    public static final String[] LABELS = {"path", "method", "status"};

    public static final double[] BUCKETS = {
        0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5
    };

    public static final Histogram HTTP_REQUEST_DURATION = Histogram.build()
        .name("http_request_duration_seconds")
        .help("End-to-end request latency in seconds")
        .buckets(BUCKETS)
        .labelNames(LABELS)
        .register();

    @PostConstruct
    void registerJvmCollectors() {
        new StandardExports().register();
        new MemoryPoolsExports().register();
    }

    public static CollectorRegistry registry() {
        return CollectorRegistry.defaultRegistry;
    }
}

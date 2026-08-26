package com.bench.metrics;

import io.prometheus.client.exporter.common.TextFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.StringWriter;

@RestController
public class MetricsController {

    @GetMapping(value = "/metrics", produces = "text/plain; version=0.0.4")
    public String metrics() throws IOException {
        StringWriter sw = new StringWriter();
        TextFormat.write004(sw, MetricsConfig.registry().metricFamilySamples());
        return sw.toString();
    }
}

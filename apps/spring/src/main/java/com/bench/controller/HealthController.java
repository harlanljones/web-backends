package com.bench.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class HealthController {

    @GetMapping("/health")
    public Map<String, String> health() {
        // No database round trip, per the contract: the process being reachable
        // is the signal. The DataSource is built at startup, so once we serve
        // HTTP the pool exists.
        return Map.of("status", "ok");
    }
}

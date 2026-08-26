package com.bench;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class BenchApplication {

    public static void main(String[] args) {
        applyLogLevel();
        SpringApplication.run(BenchApplication.class, args);
    }

    // The contract's LOG_LEVEL controls the framework's logging budget. Spring
    // Boot defaults to INFO on the root logger, which at 10k RPS would flood
    // the container's log driver. Map the shared LOG_LEVEL env var onto
    // logging.level.root before the context starts so the default is warn
    // (the published level) and per-request logging is off by default.
    private static void applyLogLevel() {
        String level = System.getenv("LOG_LEVEL");
        if (level == null || level.isBlank()) {
            level = "warn";
        }
        String root = switch (level.toLowerCase()) {
            case "error" -> "error";
            case "info" -> "info";
            case "debug" -> "debug";
            default -> "warn";
        };
        System.setProperty("logging.level.root", root);
    }
}

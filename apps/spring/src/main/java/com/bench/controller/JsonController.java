package com.bench.controller;

import com.bench.model.Models;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;

@RestController
public class JsonController {

    @GetMapping("/json")
    public Models.JsonResponse json() {
        return new Models.JsonResponse("bench", "1.0.0", Instant.now().toString());
    }
}

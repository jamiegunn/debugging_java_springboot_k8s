package com.example.debugdemo.order;

import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;

@Tag(name = "orders")
@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    @GetMapping
    public List<OrderDto.Response> list() {
        return service.findAll().stream().map(OrderDto.Response::from).toList();
    }

    @GetMapping("/{id}")
    public OrderDto.Response get(@PathVariable Long id) {
        return OrderDto.Response.from(service.findById(id));
    }

    @PostMapping
    public ResponseEntity<OrderDto.Response> create(@Valid @RequestBody OrderDto.CreateRequest req) {
        Order created = service.create(req);
        return ResponseEntity
                .created(URI.create("/api/orders/" + created.getId()))
                .body(OrderDto.Response.from(created));
    }

    @PutMapping("/{id}")
    public OrderDto.Response update(@PathVariable Long id, @Valid @RequestBody OrderDto.UpdateRequest req) {
        return OrderDto.Response.from(service.update(id, req));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}

package com.example.debugdemo.customer;

import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;

@RestController
@RequestMapping("/api/customers")
public class CustomerController {

    private final CustomerService service;

    public CustomerController(CustomerService service) {
        this.service = service;
    }

    @GetMapping
    public List<CustomerDto.Response> list() {
        return service.findAll().stream().map(CustomerDto.Response::from).toList();
    }

    @GetMapping("/{id}")
    public CustomerDto.Response get(@PathVariable Long id) {
        return CustomerDto.Response.from(service.findById(id));
    }

    @PostMapping
    public ResponseEntity<CustomerDto.Response> create(@Valid @RequestBody CustomerDto.CreateRequest req) {
        Customer created = service.create(req);
        return ResponseEntity
                .created(URI.create("/api/customers/" + created.getId()))
                .body(CustomerDto.Response.from(created));
    }

    @PutMapping("/{id}")
    public CustomerDto.Response update(@PathVariable Long id, @Valid @RequestBody CustomerDto.UpdateRequest req) {
        return CustomerDto.Response.from(service.update(id, req));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}

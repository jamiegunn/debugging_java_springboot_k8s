package com.example.debugdemo.customer;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@Transactional
public class CustomerService {

    private static final Logger log = LoggerFactory.getLogger(CustomerService.class);

    private final CustomerRepository repository;

    public CustomerService(CustomerRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    public List<Customer> findAll() {
        return repository.findAll();
    }

    @Cacheable(value = "customers", key = "#id")
    @Transactional(readOnly = true)
    public Customer findById(Long id) {
        log.info("DB hit: loading customer id={}", id);
        return repository.findById(id)
                .orElseThrow(() -> new CustomerNotFoundException(id));
    }

    public Customer create(CustomerDto.CreateRequest req) {
        return repository.save(new Customer(req.name(), req.email()));
    }

    @CacheEvict(value = "customers", key = "#id")
    public Customer update(Long id, CustomerDto.UpdateRequest req) {
        Customer c = findById(id);
        c.setName(req.name());
        c.setEmail(req.email());
        return repository.save(c);
    }

    @CacheEvict(value = "customers", key = "#id")
    public void delete(Long id) {
        if (!repository.existsById(id)) {
            throw new CustomerNotFoundException(id);
        }
        repository.deleteById(id);
    }
}

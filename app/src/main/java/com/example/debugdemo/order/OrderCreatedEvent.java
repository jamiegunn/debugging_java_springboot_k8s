package com.example.debugdemo.order;

import java.math.BigDecimal;
import java.time.Instant;

public record OrderCreatedEvent(Long orderId, Long customerId, BigDecimal amount, Instant occurredAt) {
    public static OrderCreatedEvent from(Order o) {
        return new OrderCreatedEvent(o.getId(), o.getCustomerId(), o.getAmount(), Instant.now());
    }
}

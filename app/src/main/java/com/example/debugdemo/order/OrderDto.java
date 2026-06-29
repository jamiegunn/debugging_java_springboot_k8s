package com.example.debugdemo.order;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.time.Instant;

public class OrderDto {

    public record CreateRequest(
            @NotNull Long customerId,
            @NotNull @DecimalMin(value = "0.00", inclusive = true) BigDecimal amount) {}

    public record UpdateRequest(
            @NotNull OrderStatus status,
            @NotNull @DecimalMin(value = "0.00", inclusive = true) BigDecimal amount) {}

    public record Response(Long id, Long customerId, BigDecimal amount, OrderStatus status, Instant createdAt) {
        public static Response from(Order o) {
            return new Response(o.getId(), o.getCustomerId(), o.getAmount(), o.getStatus(), o.getCreatedAt());
        }
    }
}

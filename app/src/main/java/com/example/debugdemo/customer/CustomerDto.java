package com.example.debugdemo.customer;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.Instant;

public class CustomerDto {

    public record CreateRequest(
            @NotBlank @Size(max = 200) String name,
            @NotBlank @Email @Size(max = 320) String email) {}

    public record UpdateRequest(
            @NotBlank @Size(max = 200) String name,
            @NotBlank @Email @Size(max = 320) String email) {}

    public record Response(Long id, String name, String email, Instant createdAt) {
        public static Response from(Customer c) {
            return new Response(c.getId(), c.getName(), c.getEmail(), c.getCreatedAt());
        }
    }
}

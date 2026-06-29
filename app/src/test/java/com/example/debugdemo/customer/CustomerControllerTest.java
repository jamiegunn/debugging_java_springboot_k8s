package com.example.debugdemo.customer;

import com.example.debugdemo.config.GlobalExceptionHandler;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(CustomerController.class)
@Import(GlobalExceptionHandler.class)
class CustomerControllerTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @MockBean CustomerService service;

    @Test
    void post_returns_201_with_location() throws Exception {
        Customer saved = new Customer("Alice", "alice@example.com");
        setIdViaReflection(saved, 42L);
        when(service.create(any())).thenReturn(saved);

        mvc.perform(post("/api/customers")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"Alice","email":"alice@example.com"}
                                """))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/api/customers/42"))
                .andExpect(jsonPath("$.email").value("alice@example.com"));
    }

    @Test
    void post_rejects_invalid_email() throws Exception {
        mvc.perform(post("/api/customers")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"x","email":"not-an-email"}
                                """))
                .andExpect(status().isBadRequest());
    }

    @Test
    void get_unknown_returns_404() throws Exception {
        when(service.findById(7L)).thenThrow(new CustomerNotFoundException(7L));
        mvc.perform(get("/api/customers/7"))
                .andExpect(status().isNotFound());
    }

    private static void setIdViaReflection(Customer c, Long id) throws Exception {
        var f = Customer.class.getDeclaredField("id");
        f.setAccessible(true);
        f.set(c, id);
        var cf = Customer.class.getDeclaredField("createdAt");
        cf.setAccessible(true);
        cf.set(c, Instant.now());
    }
}

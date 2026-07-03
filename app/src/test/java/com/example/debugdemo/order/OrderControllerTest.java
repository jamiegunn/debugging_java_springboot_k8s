package com.example.debugdemo.order;

import com.example.debugdemo.config.GlobalExceptionHandler;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(OrderController.class)
@Import(GlobalExceptionHandler.class)
class OrderControllerTest {

    @Autowired MockMvc mvc;
    @MockBean OrderService service;

    @Test
    void post_returns_201_with_location() throws Exception {
        Order saved = new Order(5L, new BigDecimal("19.99"));
        setViaReflection(saved, 42L);
        when(service.create(any())).thenReturn(saved);

        mvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"customerId":5,"amount":19.99}
                                """))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/api/orders/42"))
                .andExpect(jsonPath("$.customerId").value(5))
                .andExpect(jsonPath("$.status").value("NEW"));
    }

    @Test
    void post_rejects_negative_amount() throws Exception {
        mvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"customerId":5,"amount":-0.01}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").exists());
    }

    @Test
    void post_rejects_missing_customerId() throws Exception {
        mvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"amount":10.00}
                                """))
                .andExpect(status().isBadRequest());
    }

    @Test
    void post_accepts_zero_amount_boundary() throws Exception {
        // @DecimalMin("0.00", inclusive=true) — zero is a legal order amount.
        Order saved = new Order(5L, new BigDecimal("0.00"));
        setViaReflection(saved, 1L);
        when(service.create(any())).thenReturn(saved);

        mvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"customerId":5,"amount":0.00}
                                """))
                .andExpect(status().isCreated());
    }

    @Test
    void get_unknown_returns_404_problem_body() throws Exception {
        when(service.findById(7L)).thenThrow(new OrderNotFoundException(7L));

        mvc.perform(get("/api/orders/7"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.status").value(404));
    }

    @Test
    void put_rejects_unknown_status_enum_value() throws Exception {
        mvc.perform(put("/api/orders/1")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"status":"TELEPORTED","amount":10.00}
                                """))
                .andExpect(status().is4xxClientError());
    }

    @Test
    void delete_returns_204() throws Exception {
        mvc.perform(delete("/api/orders/3"))
                .andExpect(status().isNoContent());
    }

    private static void setViaReflection(Order o, Long id) throws Exception {
        var f = Order.class.getDeclaredField("id");
        f.setAccessible(true);
        f.set(o, id);
        var cf = Order.class.getDeclaredField("createdAt");
        cf.setAccessible(true);
        cf.set(o, Instant.now());
    }
}

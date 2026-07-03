package com.example.debugdemo.valkey;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class CustomerStatsTest {

    @Mock StringRedisTemplate redis;
    @Mock HashOperations<String, String, String> hashOps;

    CustomerStats stats;

    @BeforeEach
    void setUp() {
        when(redis.<String, String>opsForHash()).thenReturn(hashOps);
        stats = new CustomerStats(redis);
    }

    @Test
    void recordOrder_updates_all_three_fields_on_the_pinned_key() {
        stats.recordOrder(42L, new BigDecimal("19.99"));

        String key = "customer:stats:{42}";
        verify(hashOps).increment(key, "order_count", 1);       // HINCRBY
        verify(hashOps).increment(key, "total_spend", 19.99);   // HINCRBYFLOAT
        verify(hashOps).put(eq(key), eq("last_order_at"), anyString()); // HSET
    }

    @Test
    void orderCount_returns_zero_for_a_customer_with_no_orders() {
        // HGET on a missing field returns null — must map to 0, not NPE.
        when(hashOps.get("customer:stats:{9}", "order_count")).thenReturn(null);

        assertThat(stats.orderCount(9L)).isZero();
    }

    @Test
    void orderCount_parses_the_stored_counter() {
        when(hashOps.get("customer:stats:{9}", "order_count")).thenReturn("12");

        assertThat(stats.orderCount(9L)).isEqualTo(12L);
    }
}

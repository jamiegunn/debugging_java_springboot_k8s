package com.example.debugdemo.valkey;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.ListOperations;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class RecentOrdersTest {

    @Mock StringRedisTemplate redis;
    @Mock ListOperations<String, String> listOps;

    RecentOrders recent;

    @BeforeEach
    void setUp() {
        when(redis.opsForList()).thenReturn(listOps);
        recent = new RecentOrders(redis);
    }

    @Test
    void push_lpushes_then_trims_to_the_cap() {
        recent.push(17L, new BigDecimal("42.50"));

        // The order matters: LPUSH first, then LTRIM 0..limit-1 keeps memory
        // constant no matter how many orders flow through.
        var inOrder = inOrder(listOps);
        inOrder.verify(listOps).leftPush(ValkeyKeys.RECENT_ORDERS_LIST, "17,42.50");
        inOrder.verify(listOps).trim(ValkeyKeys.RECENT_ORDERS_LIST,
                0, ValkeyKeys.RECENT_ORDERS_LIMIT - 1L);
    }

    @Test
    void push_serializes_amount_as_plain_string_not_scientific_notation() {
        // BigDecimal("1E+3").toString() would be "1E+3" — toPlainString() must
        // be used so the list entry stays parseable as "id,amount".
        recent.push(1L, new BigDecimal("1E+3"));

        verify(listOps).leftPush(ValkeyKeys.RECENT_ORDERS_LIST, "1,1000");
    }

    @Test
    void recent_reads_exactly_n_entries_from_the_head() {
        recent.recent(20);

        verify(listOps).range(ValkeyKeys.RECENT_ORDERS_LIST, 0, 19L);
    }

    @Test
    void size_delegates_to_llen() {
        when(listOps.size(ValkeyKeys.RECENT_ORDERS_LIST)).thenReturn(7L);

        assertThat(recent.size()).isEqualTo(7L);
    }
}

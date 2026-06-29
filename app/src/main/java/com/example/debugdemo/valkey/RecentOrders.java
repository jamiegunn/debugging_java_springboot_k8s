package com.example.debugdemo.valkey;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.List;

/**
 * Capped list of the most recent orders.
 *  - LPUSH then LTRIM 0 N-1   (constant memory)
 *  - LRANGE for read
 */
@Component
public class RecentOrders {

    private final StringRedisTemplate redis;

    public RecentOrders(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /** LPUSH orders:recent "orderId,amount"  then  LTRIM orders:recent 0 N-1 */
    public void push(Long orderId, BigDecimal amount) {
        String entry = orderId + "," + amount.toPlainString();
        redis.opsForList().leftPush(ValkeyKeys.RECENT_ORDERS_LIST, entry);
        redis.opsForList().trim(ValkeyKeys.RECENT_ORDERS_LIST,
                0, ValkeyKeys.RECENT_ORDERS_LIMIT - 1L);
    }

    /** LRANGE orders:recent 0 N-1 */
    public List<String> recent(int n) {
        return redis.opsForList().range(ValkeyKeys.RECENT_ORDERS_LIST, 0, n - 1L);
    }

    /** LLEN orders:recent */
    public Long size() {
        return redis.opsForList().size(ValkeyKeys.RECENT_ORDERS_LIST);
    }
}

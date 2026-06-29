package com.example.debugdemo.valkey;

import org.springframework.data.redis.core.HashOperations;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;

/**
 * Per-customer running stats stored as a Valkey hash.
 * Keys live under {@code customer:stats:{<id>}} — the hash tag pins all keys
 * for one customer onto a single cluster shard.
 *
 *  - HINCRBY      order_count
 *  - HINCRBYFLOAT total_spend
 *  - HSET         last_order_at
 *  - HGETALL on read
 */
@Component
public class CustomerStats {

    private final StringRedisTemplate redis;
    private final HashOperations<String, String, String> hash;

    public CustomerStats(StringRedisTemplate redis) {
        this.redis = redis;
        this.hash = redis.opsForHash();
    }

    public void recordOrder(Long customerId, BigDecimal amount) {
        String key = ValkeyKeys.customerStatsKey(customerId);
        hash.increment(key, "order_count", 1);
        hash.increment(key, "total_spend", amount.doubleValue());
        hash.put(key, "last_order_at", Instant.now().toString());
    }

    public Map<String, String> get(Long customerId) {
        return hash.entries(ValkeyKeys.customerStatsKey(customerId));
    }

    public Long orderCount(Long customerId) {
        String v = hash.get(ValkeyKeys.customerStatsKey(customerId), "order_count");
        return v == null ? 0L : Long.parseLong(v);
    }
}

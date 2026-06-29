package com.example.debugdemo.valkey;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ZSetOperations.TypedTuple;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;

/**
 * Sorted-set leaderboard of customers ranked by cumulative spend.
 *  - ZINCRBY on each order
 *  - ZREVRANGE WITHSCORES for the top N
 */
@Component
public class Leaderboard {

    private final StringRedisTemplate redis;

    public Leaderboard(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /** ZINCRBY customers:top <amount> <customerId> */
    public void recordSpend(Long customerId, BigDecimal amount) {
        redis.opsForZSet().incrementScore(
                ValkeyKeys.TOP_CUSTOMERS_ZSET,
                String.valueOf(customerId),
                amount.doubleValue());
    }

    /** ZREVRANGE customers:top 0 N-1 WITHSCORES */
    public List<Entry> topN(int n) {
        Set<TypedTuple<String>> raw = redis.opsForZSet()
                .reverseRangeWithScores(ValkeyKeys.TOP_CUSTOMERS_ZSET, 0, n - 1L);
        if (raw == null) return List.of();
        return raw.stream()
                .map(t -> new Entry(Long.parseLong(t.getValue()), t.getScore()))
                .toList();
    }

    public record Entry(Long customerId, Double totalSpend) {}
}

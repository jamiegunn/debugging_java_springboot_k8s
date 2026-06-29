package com.example.debugdemo.valkey;

import com.example.debugdemo.order.OrderCreatedEvent;
import jakarta.validation.constraints.Min;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Direct endpoints for exercising each Valkey op type without going through
 * the OrderService write path. Useful for poking with curl / Postman.
 *
 * Naming convention: each endpoint mirrors the Valkey command(s) it issues.
 */
@RestController
@RequestMapping("/api/valkey")
public class ValkeyPlaygroundController {

    private final StringRedisTemplate redis;
    private final OrderEventStream stream;
    private final OrderEventPubSub pubsub;
    private final CustomerStats stats;
    private final Leaderboard leaderboard;
    private final RecentOrders recent;

    public ValkeyPlaygroundController(StringRedisTemplate redis,
                                      OrderEventStream stream,
                                      OrderEventPubSub pubsub,
                                      CustomerStats stats,
                                      Leaderboard leaderboard,
                                      RecentOrders recent) {
        this.redis = redis;
        this.stream = stream;
        this.pubsub = pubsub;
        this.stats = stats;
        this.leaderboard = leaderboard;
        this.recent = recent;
    }

    // ---------------- SET / GET (plain string keys) -----------------------

    /** SET key value [EX seconds]  →  routed to the shard owning the key. */
    @PostMapping("/kv/{key}")
    public Map<String, Object> setKey(@PathVariable String key,
                                      @RequestParam String value,
                                      @RequestParam(required = false) Long ttlSeconds) {
        if (ttlSeconds == null) {
            redis.opsForValue().set(key, value);
        } else {
            redis.opsForValue().set(key, value, java.time.Duration.ofSeconds(ttlSeconds));
        }
        return Map.of("key", key, "value", value, "ttlSeconds", String.valueOf(ttlSeconds));
    }

    /** GET key */
    @GetMapping("/kv/{key}")
    public Map<String, Object> getKey(@PathVariable String key) {
        return Map.of("key", key, "value", String.valueOf(redis.opsForValue().get(key)));
    }

    // ---------------- Pub/Sub --------------------------------------------

    /** PUBLISH orders:notifications "<msg>" — classic, broadcasts cluster-wide. */
    @PostMapping("/pubsub/publish")
    public Map<String, Object> publish(@RequestParam(defaultValue = "hello from playground") String msg) {
        OrderCreatedEvent fake = new OrderCreatedEvent(0L, 0L, BigDecimal.ZERO, Instant.now());
        Long subs = pubsub.publishClassic(synthetic(msg, fake));
        return Map.of("channel", ValkeyKeys.ORDERS_CLASSIC_CHANNEL, "deliveredTo", subs);
    }

    /** SPUBLISH {orders}:sharded "<msg>" — sharded, only delivered to subscribers on the same shard. */
    @PostMapping("/pubsub/spublish")
    public Map<String, Object> spublish(@RequestParam(defaultValue = "hello sharded") String msg) {
        OrderCreatedEvent fake = new OrderCreatedEvent(0L, 0L, BigDecimal.ZERO, Instant.now());
        Long subs = pubsub.publishSharded(synthetic(msg, fake));
        return Map.of("channel", ValkeyKeys.ORDERS_SHARDED_CHANNEL, "deliveredTo", subs);
    }

    /** Counter of pub/sub messages received by THIS replica's subscriber. */
    @GetMapping("/pubsub/received")
    public Map<String, Object> received() {
        return Map.of("received", pubsub.receivedSoFar());
    }

    // ---------------- Streams --------------------------------------------

    /** XLEN orders:events */
    @GetMapping("/streams/length")
    public Map<String, Object> streamLength() {
        return Map.of("stream", ValkeyKeys.ORDER_STREAM, "length", stream.length());
    }

    /** XADD orders:events * note "<msg>"  — synthetic event for testing. */
    @PostMapping("/streams/append")
    public Map<String, Object> streamAppend(@RequestParam(defaultValue = "manual") String note) {
        OrderCreatedEvent fake = new OrderCreatedEvent(-1L, -1L, BigDecimal.ZERO, Instant.now());
        var id = stream.append(fake);
        return Map.of("stream", ValkeyKeys.ORDER_STREAM, "id", id.getValue(), "note", note);
    }

    /** XREAD COUNT n STREAMS orders:events 0 */
    @GetMapping("/streams/read")
    public List<Map<String, Object>> streamRead(@RequestParam(defaultValue = "10") @Min(1) int count) {
        List<MapRecord<String, Object, Object>> records = stream.readLatest(count);
        if (records == null) return List.of();
        return records.stream().map(r -> {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("id", r.getId().getValue());
            out.put("data", r.getValue());
            return out;
        }).toList();
    }

    /** Counter of stream records processed by THIS replica's consumer-group member. */
    @GetMapping("/streams/consumed")
    public Map<String, Object> streamConsumed() {
        return Map.of("consumed", stream.consumedSoFar());
    }

    // ---------------- Hashes (per-customer stats) ------------------------

    /** HGETALL customer:stats:{<id>} */
    @GetMapping("/stats/{customerId}")
    public Map<String, Object> customerStats(@PathVariable Long customerId) {
        return Map.of("customerId", customerId, "stats", stats.get(customerId));
    }

    // ---------------- Sorted set (leaderboard) ---------------------------

    /** ZREVRANGE customers:top 0 N-1 WITHSCORES */
    @GetMapping("/leaderboard")
    public List<Leaderboard.Entry> leaderboard(@RequestParam(defaultValue = "10") @Min(1) int n) {
        return leaderboard.topN(n);
    }

    // ---------------- List (recent orders) -------------------------------

    /** LRANGE orders:recent 0 N-1 */
    @GetMapping("/recent")
    public Map<String, Object> recent(@RequestParam(defaultValue = "20") @Min(1) int n) {
        return Map.of(
                "size", recent.size(),
                "entries", recent.recent(n)
        );
    }

    // ---------------- helpers --------------------------------------------

    private static OrderCreatedEvent synthetic(String msg, OrderCreatedEvent template) {
        // Slip the message into the amount field for ease of demo
        return new OrderCreatedEvent(
                template.orderId(),
                template.customerId(),
                template.amount(),
                template.occurredAt()
        );
    }
}

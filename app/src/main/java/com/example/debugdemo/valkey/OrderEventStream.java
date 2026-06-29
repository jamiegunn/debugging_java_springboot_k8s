package com.example.debugdemo.valkey;

import com.example.debugdemo.order.OrderCreatedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Valkey Streams ops on {@code orders:events}.
 *  - XADD via {@link #append} on every order creation
 *  - XLEN / XREAD via {@link #length} / {@link #readLatest}
 *  - XREADGROUP via the auto-ack subscription in ValkeyOpsConfig
 */
@Component
public class OrderEventStream {

    private static final Logger log = LoggerFactory.getLogger(OrderEventStream.class);

    private final StringRedisTemplate redis;
    private final AtomicLong consumedCount = new AtomicLong();

    public OrderEventStream(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /** XADD orders:events * field1 value1 field2 value2 ... */
    public RecordId append(OrderCreatedEvent event) {
        Map<String, String> entry = Map.of(
                "orderId",    String.valueOf(event.orderId()),
                "customerId", String.valueOf(event.customerId()),
                "amount",     event.amount().toPlainString(),
                "occurredAt", event.occurredAt().toString()
        );
        RecordId id = redis.opsForStream().add(ValkeyKeys.ORDER_STREAM, entry);
        log.debug("XADD {} -> {}", ValkeyKeys.ORDER_STREAM, id);
        return id;
    }

    /** XLEN orders:events */
    public Long length() {
        return redis.opsForStream().size(ValkeyKeys.ORDER_STREAM);
    }

    /** XREAD COUNT n STREAMS orders:events $   (latest) */
    public List<MapRecord<String, Object, Object>> readLatest(int count) {
        return redis.opsForStream().read(
                StreamReadOptions.empty().count(count).block(Duration.ofMillis(100)),
                StreamOffset.create(ValkeyKeys.ORDER_STREAM, ReadOffset.from("0"))
        );
    }

    /** Called by the consumer-group subscription after each successful auto-ack. */
    public void recordProcessed(String streamId) {
        consumedCount.incrementAndGet();
    }

    public long consumedSoFar() {
        return consumedCount.get();
    }
}

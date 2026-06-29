package com.example.debugdemo.valkey;

import com.example.debugdemo.order.OrderCreatedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.Message;
import org.springframework.data.redis.connection.MessageListener;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Classic Valkey/Redis pub/sub.
 *  - PUBLISH via {@link #publishClassic}
 *  - SUBSCRIBE wired in {@code ValkeyOpsConfig.redisMessageListenerContainer}.
 *
 * <p>On a Valkey cluster, classic pub/sub messages are propagated across all
 * nodes via the cluster bus — a SUBSCRIBE on any node sees PUBLISHes from
 * anywhere. That's why the single-shared-LB pattern works for classic pub/sub
 * even when key ops would need MOVED-aware clients.
 *
 * <p>For the sharded variant ({@code SPUBLISH}/{@code SSUBSCRIBE}), messages
 * stay on the shard owning the channel name's hash slot. Spring Data Redis
 * doesn't have first-class sharded pub/sub yet (as of 3.3), so we expose
 * {@link #publishSharded} via the low-level command interface for
 * demonstration but don't wire a sharded subscriber.
 */
@Component
public class OrderEventPubSub implements MessageListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventPubSub.class);

    private final StringRedisTemplate redis;
    private final AtomicLong received = new AtomicLong();

    public OrderEventPubSub(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /** PUBLISH orders:notifications "<json>" */
    public Long publishClassic(OrderCreatedEvent event) {
        String payload = "orderId=" + event.orderId() +
                ",customerId=" + event.customerId() +
                ",amount=" + event.amount();
        Long subscribers = redis.convertAndSend(ValkeyKeys.ORDERS_CLASSIC_CHANNEL, payload);
        log.debug("PUBLISH {} -> {} subscriber(s)", ValkeyKeys.ORDERS_CLASSIC_CHANNEL, subscribers);
        return subscribers;
    }

    /**
     * SPUBLISH {orders}:sharded "<json>" — sharded pub/sub. Message goes only
     * to nodes whose subscribers used SSUBSCRIBE on the same channel name.
     *
     * <p>Spring Data Redis 3.3 has no first-class API for sharded pub/sub, and
     * Lettuce 6.3's typed {@code spublish} sits on {@code RedisPubSubCommands}
     * (different connection type than the standard cluster commands). Easiest
     * path that works with any Lettuce 6.x: send via generic {@code dispatch}
     * with an {@code IntegerOutput} so the subscriber count parses cleanly.
     */
    public Long publishSharded(OrderCreatedEvent event) {
        String payload = "orderId=" + event.orderId() +
                ",customerId=" + event.customerId() +
                ",amount=" + event.amount();

        // Spring Data Redis 3.3 has no first-class API for sharded pub/sub.
        // LettuceConnection.getNativeConnection() returns the underlying
        // Lettuce async commands object; we dispatch SPUBLISH on it directly
        // (it routes the command to the shard owning the channel name's slot)
        // and await the integer subscriber count.
        @SuppressWarnings("unchecked")
        io.lettuce.core.cluster.api.async.RedisAdvancedClusterAsyncCommands<String, String> asyncCmds =
                (io.lettuce.core.cluster.api.async.RedisAdvancedClusterAsyncCommands<String, String>)
                        redis.getRequiredConnectionFactory().getConnection().getNativeConnection();

        io.lettuce.core.protocol.ProtocolKeyword spublish =
                new io.lettuce.core.protocol.ProtocolKeyword() {
                    @Override public byte[] getBytes() { return "SPUBLISH".getBytes(); }
                    @Override public String name()     { return "SPUBLISH"; }
                };
        io.lettuce.core.RedisFuture<Long> future = asyncCmds.dispatch(
                spublish,
                new io.lettuce.core.output.IntegerOutput<>(io.lettuce.core.codec.StringCodec.UTF8),
                new io.lettuce.core.protocol.CommandArgs<>(io.lettuce.core.codec.StringCodec.UTF8)
                        .addKey(ValkeyKeys.ORDERS_SHARDED_CHANNEL)
                        .addValue(payload));
        Long subscribers;
        try {
            subscribers = future.get(5, java.util.concurrent.TimeUnit.SECONDS);
        } catch (Exception e) {
            throw new org.springframework.data.redis.RedisSystemException("SPUBLISH failed", e);
        }
        log.debug("SPUBLISH {} -> {} subscriber(s)", ValkeyKeys.ORDERS_SHARDED_CHANNEL, subscribers);
        return subscribers;
    }

    /** Classic-pubsub listener for orders:notifications. */
    @Override
    public void onMessage(Message message, byte[] pattern) {
        long n = received.incrementAndGet();
        log.info("PUBSUB received #{} on {}: {}",
                n, new String(message.getChannel()), new String(message.getBody()));
    }

    public long receivedSoFar() {
        return received.get();
    }
}

package com.example.debugdemo.config;

import com.example.debugdemo.valkey.OrderEventPubSub;
import com.example.debugdemo.valkey.OrderEventStream;
import com.example.debugdemo.valkey.ValkeyKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;
import org.springframework.data.redis.stream.StreamMessageListenerContainer;
import org.springframework.data.redis.stream.Subscription;

import java.time.Duration;
import java.util.UUID;

/**
 * Beans for direct Valkey ops: pub/sub listener container, stream consumer
 * group container, and the actual subscriptions that wire our app's listener
 * components in.
 *
 * The plain {@link StringRedisTemplate} bean is autoconfigured by Spring Boot;
 * we don't need to declare it here.
 */
@Configuration
public class ValkeyOpsConfig {

    private static final Logger log = LoggerFactory.getLogger(ValkeyOpsConfig.class);

    /** Container that dispatches classic pub/sub messages to MessageListeners. */
    @Bean
    public RedisMessageListenerContainer redisMessageListenerContainer(RedisConnectionFactory cf,
                                                                       OrderEventPubSub pubsub) {
        RedisMessageListenerContainer c = new RedisMessageListenerContainer();
        c.setConnectionFactory(cf);
        c.addMessageListener(pubsub, new ChannelTopic(ValkeyKeys.ORDERS_CLASSIC_CHANNEL));
        return c;
    }

    /**
     * Container for stream consumption with consumer groups.
     * Auto-acks each record after the listener returns successfully; for
     * at-least-once semantics or manual ack, drop autoAck and call XACK explicitly.
     */
    @Bean(destroyMethod = "stop")
    public StreamMessageListenerContainer<String, MapRecord<String, String, String>>
            streamListenerContainer(RedisConnectionFactory cf) {
        var options = StreamMessageListenerContainer.StreamMessageListenerContainerOptions
                .builder()
                .pollTimeout(Duration.ofSeconds(2))
                .batchSize(10)
                .build();
        var container = StreamMessageListenerContainer.create(cf, options);
        container.start();
        return container;
    }

    /**
     * Subscribe THIS app instance to the order stream as a member of a shared
     * consumer group. Multiple replicas share the work — only one replica
     * sees each record.
     */
    @Bean
    public Subscription orderStreamSubscription(
            StreamMessageListenerContainer<String, MapRecord<String, String, String>> container,
            OrderEventStream streamOps,
            StringRedisTemplate redis,
            ObjectMapper mapper) {

        String groupName = "order-processors";
        String consumerName = "consumer-" + UUID.randomUUID().toString().substring(0, 8);

        // Create the consumer group if it doesn't exist. MKSTREAM creates the stream
        // too if no producer has yet. XGROUP CREATE fails if the group exists — we
        // swallow that.
        try {
            redis.opsForStream().createGroup(ValkeyKeys.ORDER_STREAM, ReadOffset.from("0"), groupName);
            log.info("Created consumer group '{}' on stream '{}'", groupName, ValkeyKeys.ORDER_STREAM);
        } catch (Exception e) {
            log.debug("Consumer group '{}' likely already exists: {}", groupName, e.getMessage());
        }

        Subscription sub = container.receiveAutoAck(
                Consumer.from(groupName, consumerName),
                StreamOffset.create(ValkeyKeys.ORDER_STREAM, ReadOffset.lastConsumed()),
                record -> {
                    try {
                        log.info("STREAM consume id={} payload={}", record.getId(), record.getValue());
                        streamOps.recordProcessed(record.getId().getValue());
                    } catch (Exception ex) {
                        log.warn("stream listener error", ex);
                    }
                });
        log.info("Stream subscription started: group={} consumer={}", groupName, consumerName);
        return sub;
    }
}

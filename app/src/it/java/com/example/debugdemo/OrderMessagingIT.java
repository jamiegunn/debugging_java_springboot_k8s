package com.example.debugdemo;

import com.example.debugdemo.order.OrderCreatedEvent;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.jms.core.JmsTemplate;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static java.time.Duration.ofSeconds;

class OrderMessagingIT extends AbstractIntegrationTest {

    @Autowired TestRestTemplate rest;
    @Autowired JmsTemplate jmsTemplate;

    @Test
    void posting_order_publishes_event_to_outbound_queue() {
        Map<String, Object> customerBody = Map.of("name", "Bob", "email", "bob@example.com");
        Number customerId = (Number) rest.postForEntity("/api/customers", customerBody, Map.class)
                .getBody().get("id");

        rest.postForEntity("/api/orders",
                Map.of("customerId", customerId, "amount", 49.99), Map.class);

        await().atMost(ofSeconds(30)).untilAsserted(() -> {
            jmsTemplate.setReceiveTimeout(2_000);
            Object received = jmsTemplate.receiveAndConvert("DEV.QUEUE.1");
            assertThat(received).isInstanceOf(OrderCreatedEvent.class);
            OrderCreatedEvent evt = (OrderCreatedEvent) received;
            assertThat(evt.customerId().longValue()).isEqualTo(customerId.longValue());
        });
    }
}

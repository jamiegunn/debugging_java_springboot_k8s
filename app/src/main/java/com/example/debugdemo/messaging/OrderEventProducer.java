package com.example.debugdemo.messaging;

import com.example.debugdemo.order.OrderCreatedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.stereotype.Component;

@Component
public class OrderEventProducer {

    private static final Logger log = LoggerFactory.getLogger(OrderEventProducer.class);

    private final JmsTemplate jmsTemplate;
    private final MqProperties properties;

    public OrderEventProducer(JmsTemplate jmsTemplate, MqProperties properties) {
        this.jmsTemplate = jmsTemplate;
        this.properties = properties;
    }

    public void publishOrderCreated(OrderCreatedEvent event) {
        log.info("Publishing OrderCreatedEvent orderId={} queue={}", event.orderId(), properties.getOutboundQueue());
        jmsTemplate.convertAndSend(properties.getOutboundQueue(), event);
    }
}

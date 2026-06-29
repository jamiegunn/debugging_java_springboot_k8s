package com.example.debugdemo.messaging;

import com.example.debugdemo.order.OrderNotFoundException;
import com.example.debugdemo.order.OrderService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jms.annotation.JmsListener;
import org.springframework.stereotype.Component;

@Component
public class InboundCommandListener {

    private static final Logger log = LoggerFactory.getLogger(InboundCommandListener.class);

    private final OrderService orderService;

    public InboundCommandListener(OrderService orderService) {
        this.orderService = orderService;
    }

    @JmsListener(destination = "${app.mq.inbound-queue}")
    public void onCommand(InboundCommand command) {
        log.info("Received inbound command orderId={} targetStatus={}", command.orderId(), command.targetStatus());
        try {
            orderService.updateStatus(command.orderId(), command.targetStatus());
        } catch (OrderNotFoundException e) {
            log.warn("Ignoring command for missing order {}", command.orderId());
        }
    }
}

package com.example.debugdemo.messaging;

import com.example.debugdemo.order.OrderStatus;

public record InboundCommand(Long orderId, OrderStatus targetStatus) {}

package com.example.debugdemo.order;

import com.example.debugdemo.messaging.OrderEventProducer;
import com.example.debugdemo.valkey.CustomerStats;
import com.example.debugdemo.valkey.Leaderboard;
import com.example.debugdemo.valkey.OrderEventPubSub;
import com.example.debugdemo.valkey.OrderEventStream;
import com.example.debugdemo.valkey.RecentOrders;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock OrderRepository repository;
    @Mock OrderEventProducer producer;
    @Mock OrderEventStream stream;
    @Mock OrderEventPubSub pubsub;
    @Mock CustomerStats stats;
    @Mock Leaderboard leaderboard;
    @Mock RecentOrders recent;
    @InjectMocks OrderService service;

    @Test
    void create_saves_order_and_publishes_event() {
        when(repository.save(any(Order.class))).thenAnswer(inv -> {
            Order o = inv.getArgument(0);
            // simulate ID assignment via reflection-free path: not strictly needed for the assertions below
            return o;
        });

        service.create(new OrderDto.CreateRequest(5L, new BigDecimal("19.99")));

        ArgumentCaptor<OrderCreatedEvent> evt = ArgumentCaptor.forClass(OrderCreatedEvent.class);
        verify(producer).publishOrderCreated(evt.capture());
        assertThat(evt.getValue().customerId()).isEqualTo(5L);
        assertThat(evt.getValue().amount()).isEqualByComparingTo("19.99");
    }

    @Test
    void updateStatus_modifies_existing_order() {
        Order existing = new Order(1L, BigDecimal.TEN);
        when(repository.findById(99L)).thenReturn(Optional.of(existing));
        when(repository.save(existing)).thenReturn(existing);

        Order updated = service.updateStatus(99L, OrderStatus.SHIPPED);

        assertThat(updated.getStatus()).isEqualTo(OrderStatus.SHIPPED);
    }
}

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
import org.springframework.data.redis.RedisConnectionFailureException;

import java.math.BigDecimal;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
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
        when(repository.save(any(Order.class))).thenAnswer(inv -> inv.getArgument(0));

        service.create(new OrderDto.CreateRequest(5L, new BigDecimal("19.99")));

        ArgumentCaptor<OrderCreatedEvent> evt = ArgumentCaptor.forClass(OrderCreatedEvent.class);
        verify(producer).publishOrderCreated(evt.capture());
        assertThat(evt.getValue().customerId()).isEqualTo(5L);
        assertThat(evt.getValue().amount()).isEqualByComparingTo("19.99");
    }

    @Test
    void create_fans_out_to_every_valkey_op_type() {
        // One POST /api/orders must hit 5 different Valkey op types (stream,
        // classic pub/sub, hash, zset, list) plus MQ — this is the integration
        // write path the whole demo is built around. Pin the full fan-out.
        when(repository.save(any(Order.class))).thenAnswer(inv -> inv.getArgument(0));

        service.create(new OrderDto.CreateRequest(7L, new BigDecimal("42.50")));

        verify(producer).publishOrderCreated(any(OrderCreatedEvent.class));   // MQ
        verify(stream).append(any(OrderCreatedEvent.class));                  // XADD
        verify(pubsub).publishClassic(any(OrderCreatedEvent.class));          // PUBLISH
        verify(stats).recordOrder(eq(7L), eq(new BigDecimal("42.50")));       // HINCRBY/HSET
        verify(leaderboard).recordSpend(eq(7L), eq(new BigDecimal("42.50"))); // ZINCRBY
        verify(recent).push(any(), eq(new BigDecimal("42.50")));              // LPUSH+LTRIM
    }

    @Test
    void create_propagates_valkey_failure_after_db_and_mq_succeeded() {
        // Pins CURRENT behavior: the Valkey side-effects are NOT guarded, so a
        // Valkey outage fails the whole request even though the DB write and MQ
        // publish already happened. This is deliberate — the app is a debugging
        // target and this is one of the failure modes the chaos tooling
        // (scripts/chaos.sh valkey-down) demonstrates. If create() is ever made
        // resilient (catch + degrade), update this test AND the chaos docs.
        when(repository.save(any(Order.class))).thenAnswer(inv -> inv.getArgument(0));
        doThrow(new RedisConnectionFailureException("valkey down")).when(stream).append(any());

        assertThatThrownBy(() -> service.create(new OrderDto.CreateRequest(1L, BigDecimal.ONE)))
                .isInstanceOf(RedisConnectionFailureException.class);

        verify(producer).publishOrderCreated(any());      // MQ publish already happened
        verify(stats, never()).recordOrder(any(), any()); // fan-out stops at the failure
        verify(recent, never()).push(any(), any());
    }

    @Test
    void create_propagates_mq_failure_before_any_valkey_op() {
        // MQ publish comes first in the fan-out; if it fails, no Valkey op runs.
        when(repository.save(any(Order.class))).thenAnswer(inv -> inv.getArgument(0));
        doThrow(new RuntimeException("broker unreachable")).when(producer).publishOrderCreated(any());

        assertThatThrownBy(() -> service.create(new OrderDto.CreateRequest(1L, BigDecimal.TEN)))
                .hasMessageContaining("broker unreachable");

        verifyNoInteractions(stream, pubsub, stats, leaderboard, recent);
    }

    @Test
    void findById_throws_when_missing() {
        when(repository.findById(404L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.findById(404L))
                .isInstanceOf(OrderNotFoundException.class)
                .hasMessageContaining("404");
    }

    @Test
    void updateStatus_modifies_existing_order() {
        Order existing = new Order(1L, BigDecimal.TEN);
        when(repository.findById(99L)).thenReturn(Optional.of(existing));
        when(repository.save(existing)).thenReturn(existing);

        Order updated = service.updateStatus(99L, OrderStatus.SHIPPED);

        assertThat(updated.getStatus()).isEqualTo(OrderStatus.SHIPPED);
    }

    @Test
    void updateStatus_throws_when_missing() {
        when(repository.findById(anyLong())).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.updateStatus(5L, OrderStatus.SHIPPED))
                .isInstanceOf(OrderNotFoundException.class);
        verify(repository, never()).save(any());
    }

    @Test
    void delete_throws_when_missing() {
        when(repository.existsById(8L)).thenReturn(false);

        assertThatThrownBy(() -> service.delete(8L))
                .isInstanceOf(OrderNotFoundException.class);
        verify(repository, never()).deleteById(any());
    }

    @Test
    void delete_removes_existing_order() {
        when(repository.existsById(8L)).thenReturn(true);

        service.delete(8L);

        verify(repository).deleteById(8L);
    }
}

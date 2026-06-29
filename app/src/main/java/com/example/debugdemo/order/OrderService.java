package com.example.debugdemo.order;

import com.example.debugdemo.messaging.OrderEventProducer;
import com.example.debugdemo.valkey.CustomerStats;
import com.example.debugdemo.valkey.Leaderboard;
import com.example.debugdemo.valkey.OrderEventPubSub;
import com.example.debugdemo.valkey.OrderEventStream;
import com.example.debugdemo.valkey.RecentOrders;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@Transactional
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    private final OrderRepository repository;
    private final OrderEventProducer producer;
    private final OrderEventStream stream;
    private final OrderEventPubSub pubsub;
    private final CustomerStats stats;
    private final Leaderboard leaderboard;
    private final RecentOrders recent;

    public OrderService(OrderRepository repository,
                        OrderEventProducer producer,
                        OrderEventStream stream,
                        OrderEventPubSub pubsub,
                        CustomerStats stats,
                        Leaderboard leaderboard,
                        RecentOrders recent) {
        this.repository = repository;
        this.producer = producer;
        this.stream = stream;
        this.pubsub = pubsub;
        this.stats = stats;
        this.leaderboard = leaderboard;
        this.recent = recent;
    }

    @Transactional(readOnly = true)
    public List<Order> findAll() {
        return repository.findAll();
    }

    @Cacheable(value = "orders", key = "#id")
    @Transactional(readOnly = true)
    public Order findById(Long id) {
        log.info("DB hit: loading order id={}", id);
        return repository.findById(id)
                .orElseThrow(() -> new OrderNotFoundException(id));
    }

    public Order create(OrderDto.CreateRequest req) {
        Order saved = repository.save(new Order(req.customerId(), req.amount()));
        OrderCreatedEvent event = OrderCreatedEvent.from(saved);

        // MQ (existing, durable)
        producer.publishOrderCreated(event);

        // Valkey side-effects — each exercises a different op type & shard
        stream.append(event);                                              // XADD  (stream)
        pubsub.publishClassic(event);                                      // PUBLISH (classic pub/sub)
        stats.recordOrder(saved.getCustomerId(), saved.getAmount());       // HINCRBY/HSET (hash)
        leaderboard.recordSpend(saved.getCustomerId(), saved.getAmount()); // ZINCRBY (zset)
        recent.push(saved.getId(), saved.getAmount());                     // LPUSH+LTRIM (list)

        return saved;
    }

    @CacheEvict(value = "orders", key = "#id")
    public Order update(Long id, OrderDto.UpdateRequest req) {
        Order o = findById(id);
        o.setStatus(req.status());
        o.setAmount(req.amount());
        return repository.save(o);
    }

    @CacheEvict(value = "orders", key = "#id")
    public void delete(Long id) {
        if (!repository.existsById(id)) {
            throw new OrderNotFoundException(id);
        }
        repository.deleteById(id);
    }

    @CacheEvict(value = "orders", key = "#id")
    public Order updateStatus(Long id, OrderStatus status) {
        Order o = findById(id);
        o.setStatus(status);
        return repository.save(o);
    }
}

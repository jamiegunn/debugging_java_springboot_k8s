package com.example.debugdemo.valkey;

/**
 * All Valkey key names in one place. Hash tags {customer:N} group per-customer
 * keys onto the same cluster shard so multi-key commands (and just locality)
 * work; non-per-customer keys deliberately omit hash tags.
 */
public final class ValkeyKeys {

    private ValkeyKeys() {}

    // Stream of all order events (single key, single shard — typical for streams)
    public static final String ORDER_STREAM = "orders:events";

    // Pub/Sub channels
    public static final String ORDERS_CLASSIC_CHANNEL = "orders:notifications";
    public static final String ORDERS_SHARDED_CHANNEL = "{orders}:sharded";

    // Sorted set: customers ranked by total spend
    public static final String TOP_CUSTOMERS_ZSET = "customers:top";

    // List of recent orders (capped via LTRIM)
    public static final String RECENT_ORDERS_LIST = "orders:recent";
    public static final int RECENT_ORDERS_LIMIT = 100;

    // Per-customer stats hash. Hash tag pins keys for this customer to one shard
    // so future multi-key ops on a single customer never cross-shard.
    public static String customerStatsKey(Long customerId) {
        return "customer:stats:{" + customerId + "}";
    }
}

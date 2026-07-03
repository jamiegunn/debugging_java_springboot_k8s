package com.example.debugdemo.valkey;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Proves the hash-tag slot-pinning contract with the SAME slot math the
 * cluster uses: slot = CRC16(effective-key) mod 16384, where the effective
 * key is the substring between the first '{' and the next '}' when present.
 * If someone "simplifies" a key format and breaks pinning, this fails.
 */
class ValkeyKeysTest {

    @Test
    void customerStatsKey_carries_the_customer_hash_tag() {
        assertThat(ValkeyKeys.customerStatsKey(42L)).isEqualTo("customer:stats:{42}");
    }

    @Test
    void keys_for_the_same_customer_hash_to_the_same_cluster_slot() {
        // Any key that embeds {<id>} lands on the slot of "<id>" alone. So a
        // hypothetical second per-customer key would co-locate with the stats
        // hash — that's the entire point of the tag.
        String statsKey = ValkeyKeys.customerStatsKey(42L);
        String hypotheticalOrdersKey = "customer:orders:{42}";

        assertThat(clusterSlot(statsKey))
                .isEqualTo(clusterSlot(hypotheticalOrdersKey))
                .isEqualTo(clusterSlot("42"));
    }

    @Test
    void keys_for_different_customers_are_free_to_land_on_different_slots() {
        // Not guaranteed distinct for every pair (16384 slots), but these two
        // specific IDs hash apart — a canary that the tag isn't constant.
        assertThat(clusterSlot(ValkeyKeys.customerStatsKey(1L)))
                .isNotEqualTo(clusterSlot(ValkeyKeys.customerStatsKey(2L)));
    }

    @Test
    void sharded_channel_uses_the_orders_hash_tag() {
        // {orders}:sharded pins the sharded pub/sub channel to the slot of
        // "orders" — subscribers must connect to that specific shard.
        assertThat(ValkeyKeys.ORDERS_SHARDED_CHANNEL).startsWith("{orders}");
        assertThat(clusterSlot(ValkeyKeys.ORDERS_SHARDED_CHANNEL))
                .isEqualTo(clusterSlot("orders"));
    }

    @Test
    void global_keys_deliberately_have_no_hash_tag() {
        // Streams / zset / list keys are cluster-global; a hash tag would be
        // meaningless (single key each) and misleading.
        assertThat(ValkeyKeys.ORDER_STREAM).doesNotContain("{");
        assertThat(ValkeyKeys.TOP_CUSTOMERS_ZSET).doesNotContain("{");
        assertThat(ValkeyKeys.RECENT_ORDERS_LIST).doesNotContain("{");
    }

    // ------------------------------------------------------------------
    // Reference implementation of Redis/Valkey cluster key hashing:
    // CRC16-CCITT (XMODEM variant, poly 0x1021, init 0) over the hash tag
    // (or the whole key when no non-empty tag exists), mod 16384.
    // ------------------------------------------------------------------
    static int clusterSlot(String key) {
        int open = key.indexOf('{');
        if (open >= 0) {
            int close = key.indexOf('}', open + 1);
            if (close > open + 1) { // non-empty tag only
                key = key.substring(open + 1, close);
            }
        }
        return crc16(key.getBytes(java.nio.charset.StandardCharsets.UTF_8)) % 16384;
    }

    private static int crc16(byte[] data) {
        int crc = 0;
        for (byte b : data) {
            crc ^= (b & 0xFF) << 8;
            for (int i = 0; i < 8; i++) {
                crc = ((crc & 0x8000) != 0) ? (crc << 1) ^ 0x1021 : crc << 1;
                crc &= 0xFFFF;
            }
        }
        return crc;
    }
}

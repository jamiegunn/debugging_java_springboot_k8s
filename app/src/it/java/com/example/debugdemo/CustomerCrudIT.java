package com.example.debugdemo;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerCrudIT extends AbstractIntegrationTest {

    @Autowired TestRestTemplate rest;

    @Test
    void full_crud_roundtrip() {
        ResponseEntity<Map> created = rest.postForEntity("/api/customers",
                Map.of("name", "Alice", "email", "alice@example.com"), Map.class);
        assertThat(created.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        Number id = (Number) created.getBody().get("id");

        ResponseEntity<Map> fetched = rest.getForEntity("/api/customers/" + id, Map.class);
        assertThat(fetched.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(fetched.getBody().get("email")).isEqualTo("alice@example.com");

        rest.put("/api/customers/" + id, Map.of("name", "Alice B", "email", "alice2@example.com"));
        fetched = rest.getForEntity("/api/customers/" + id, Map.class);
        assertThat(fetched.getBody().get("name")).isEqualTo("Alice B");

        rest.delete("/api/customers/" + id);
        ResponseEntity<Map> after = rest.getForEntity("/api/customers/" + id, Map.class);
        assertThat(after.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }
}

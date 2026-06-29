package com.example.debugdemo;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerBatchLoadIT extends AbstractIntegrationTest {

    @Autowired TestRestTemplate rest;
    @Autowired JdbcTemplate jdbc;

    @Test
    void batch_loads_csv_into_customers(@TempDir Path tmp) throws Exception {
        Path csv = tmp.resolve("customers.csv");
        StringBuilder sb = new StringBuilder("name,email\n");
        for (int i = 0; i < 500; i++) {
            sb.append("Loaded ").append(i).append(",loaded").append(i).append("@example.com\n");
        }
        Files.writeString(csv, sb.toString());

        Integer before = jdbc.queryForObject("SELECT COUNT(*) FROM customers", Integer.class);

        ResponseEntity<Map> resp = rest.postForEntity(
                "/api/batch/customers/load?file=" + csv.toAbsolutePath(), null, Map.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.ACCEPTED);

        Integer after = jdbc.queryForObject("SELECT COUNT(*) FROM customers", Integer.class);
        assertThat(after - before).isEqualTo(500);
    }
}

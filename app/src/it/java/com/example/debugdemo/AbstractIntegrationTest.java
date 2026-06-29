package com.example.debugdemo;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.oracle.OracleContainer;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
@Testcontainers
public abstract class AbstractIntegrationTest {

    @Container
    static final OracleContainer ORACLE = new OracleContainer(
            DockerImageName.parse("gvenzl/oracle-free:23-slim-faststart"))
            .withDatabaseName("FREEPDB1")
            .withUsername("appuser")
            .withPassword("appuser");

    @Container
    static final GenericContainer<?> MQ = new GenericContainer<>(
            DockerImageName.parse("icr.io/ibm-messaging/mq:9.4.0.0-r3"))
            .withEnv("LICENSE", "accept")
            .withEnv("MQ_QMGR_NAME", "QM1")
            .withEnv("MQ_APP_PASSWORD", "passw0rd")
            .withExposedPorts(1414, 9443)
            .waitingFor(Wait.forLogMessage(".*Started web server.*\\n", 1)
                    .withStartupTimeout(Duration.ofMinutes(5)));

    @DynamicPropertySource
    static void wireProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", ORACLE::getJdbcUrl);
        registry.add("spring.datasource.username", ORACLE::getUsername);
        registry.add("spring.datasource.password", ORACLE::getPassword);

        registry.add("ibm.mq.queue-manager", () -> "QM1");
        registry.add("ibm.mq.channel", () -> "DEV.APP.SVRCONN");
        registry.add("ibm.mq.conn-name", () -> MQ.getHost() + "(" + MQ.getMappedPort(1414) + ")");
        registry.add("ibm.mq.user", () -> "app");
        registry.add("ibm.mq.password", () -> "passw0rd");
    }
}

package com.example.debugdemo.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.info.License;
import io.swagger.v3.oas.models.tags.Tag;
import java.util.List;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
class OpenApiConfig {

    @Bean
    OpenAPI debugDemoOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("debug-demo-app API")
                        .version("v1")
                        .description("Spring Boot 3.3 service used as the target for JVM debugging tooling on k8s. "
                                + "Exercises Oracle (JDBC), IBM MQ (JMS), and Valkey cluster (streams, pub/sub, hash, "
                                + "zset, list) so the diagnostic scripts have realistic integration surface to operate on.")
                        .contact(new Contact().name("debug-demo").url("https://github.com/debugging_java_springboot_k8s"))
                        .license(new License().name("Apache-2.0")))
                .tags(List.of(
                        new Tag().name("customers").description("Customer CRUD — exercises Oracle JDBC + Spring Cache (Valkey)"),
                        new Tag().name("orders").description("Order CRUD — exercises Oracle + MQ publish + 5 Valkey op types in one write"),
                        new Tag().name("batch").description("Spring Batch CSV → JDBC bulk load (long-running, good for thread/CPU probes)"),
                        new Tag().name("valkey").description("Direct Valkey op playground — every cluster op type, isolated endpoints")));
    }
}

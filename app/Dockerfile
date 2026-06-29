# syntax=docker/dockerfile:1.7

FROM maven:3.9-eclipse-temurin-25 AS builder
WORKDIR /build
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -DskipTests package

FROM eclipse-temurin:25-jre-alpine AS runtime
RUN apk add --no-cache curl tini && \
    addgroup -S app && adduser -S -G app -u 1000 app && \
    mkdir -p /app /tmp/heapdumps && chown -R app:app /app /tmp/heapdumps

WORKDIR /app
COPY --from=builder /build/target/debug-demo-app.jar /app/app.jar

ENV JAVA_OPTS="-XX:+UseContainerSupport \
    -XX:MaxRAMPercentage=75.0 \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:HeapDumpPath=/tmp/heapdumps \
    -XX:+ExitOnOutOfMemoryError"

USER app
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:8080/actuator/health/liveness || exit 1

ENTRYPOINT ["/sbin/tini", "--", "sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]

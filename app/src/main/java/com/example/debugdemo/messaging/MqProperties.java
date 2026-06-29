package com.example.debugdemo.messaging;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.mq")
public class MqProperties {

    private String outboundQueue = "DEV.QUEUE.1";
    private String inboundQueue = "DEV.QUEUE.2";

    public String getOutboundQueue() { return outboundQueue; }
    public void setOutboundQueue(String outboundQueue) { this.outboundQueue = outboundQueue; }

    public String getInboundQueue() { return inboundQueue; }
    public void setInboundQueue(String inboundQueue) { this.inboundQueue = inboundQueue; }
}

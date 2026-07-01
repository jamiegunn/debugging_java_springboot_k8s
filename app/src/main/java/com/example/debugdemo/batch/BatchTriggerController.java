package com.example.debugdemo.batch;

import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.JobParameters;
import org.springframework.batch.core.JobParametersBuilder;
import org.springframework.batch.core.launch.JobLauncher;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@Tag(name = "batch")
@RestController
@RequestMapping("/api/batch")
public class BatchTriggerController {

    private final JobLauncher jobLauncher;
    private final Job customerLoadJob;

    public BatchTriggerController(JobLauncher jobLauncher, Job customerLoadJob) {
        this.jobLauncher = jobLauncher;
        this.customerLoadJob = customerLoadJob;
    }

    @PostMapping("/customers/load")
    public ResponseEntity<Map<String, Object>> loadCustomers(@RequestParam String file) throws Exception {
        JobParameters params = new JobParametersBuilder()
                .addString(CustomerLoadJobConfig.PARAM_FILE, file)
                .addLong("submittedAt", System.currentTimeMillis())
                .toJobParameters();
        var execution = jobLauncher.run(customerLoadJob, params);
        return ResponseEntity.accepted().body(Map.of(
                "executionId", execution.getId(),
                "status", execution.getStatus().name(),
                "file", file
        ));
    }
}

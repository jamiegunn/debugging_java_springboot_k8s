package com.example.debugdemo.batch;

import org.springframework.batch.core.Job;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.database.JdbcBatchItemWriter;
import org.springframework.batch.item.database.builder.JdbcBatchItemWriterBuilder;
import org.springframework.batch.item.file.FlatFileItemReader;
import org.springframework.batch.item.file.builder.FlatFileItemReaderBuilder;
import org.springframework.batch.item.file.mapping.BeanWrapperFieldSetMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.FileSystemResource;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.time.Instant;

@Configuration
public class CustomerLoadJobConfig {

    public static final String JOB_NAME = "customerLoadJob";
    public static final String PARAM_FILE = "inputFile";

    @Bean
    @org.springframework.batch.core.configuration.annotation.StepScope
    public FlatFileItemReader<CustomerCsvRow> customerReader(
            @Value("#{jobParameters['" + PARAM_FILE + "']}") String inputFile) {
        return new FlatFileItemReaderBuilder<CustomerCsvRow>()
                .name("customerReader")
                .resource(new FileSystemResource(inputFile))
                .linesToSkip(1)
                .delimited()
                .delimiter(",")
                .names("name", "email")
                .fieldSetMapper(new BeanWrapperFieldSetMapper<>() {{
                    setTargetType(CustomerCsvRow.class);
                }})
                .build();
    }

    @Bean
    public JdbcBatchItemWriter<CustomerCsvRow> customerWriter(DataSource dataSource) {
        return new JdbcBatchItemWriterBuilder<CustomerCsvRow>()
                .dataSource(dataSource)
                .sql("INSERT INTO customers (name, email, created_at) VALUES (:name, :email, :createdAt)")
                .itemSqlParameterSourceProvider(item -> {
                    var src = new org.springframework.jdbc.core.namedparam.MapSqlParameterSource();
                    src.addValue("name", item.getName());
                    src.addValue("email", item.getEmail());
                    src.addValue("createdAt", java.sql.Timestamp.from(Instant.now()));
                    return src;
                })
                .build();
    }

    @Bean
    public Step customerLoadStep(JobRepository jobRepository,
                                 PlatformTransactionManager txManager,
                                 FlatFileItemReader<CustomerCsvRow> customerReader,
                                 JdbcBatchItemWriter<CustomerCsvRow> customerWriter,
                                 @Value("${app.batch.chunk-size:1000}") int chunkSize) {
        return new StepBuilder("customerLoadStep", jobRepository)
                .<CustomerCsvRow, CustomerCsvRow>chunk(chunkSize, txManager)
                .reader(customerReader)
                .writer(customerWriter)
                .build();
    }

    @Bean
    public Job customerLoadJob(JobRepository jobRepository, Step customerLoadStep) {
        return new JobBuilder(JOB_NAME, jobRepository)
                .start(customerLoadStep)
                .build();
    }
}

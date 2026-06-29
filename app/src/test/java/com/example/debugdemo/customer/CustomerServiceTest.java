package com.example.debugdemo.customer;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class CustomerServiceTest {

    @Mock CustomerRepository repository;
    @InjectMocks CustomerService service;

    @Test
    void create_persists_new_customer() {
        when(repository.save(any(Customer.class))).thenAnswer(inv -> inv.getArgument(0));

        Customer c = service.create(new CustomerDto.CreateRequest("Alice", "alice@example.com"));

        assertThat(c.getName()).isEqualTo("Alice");
        assertThat(c.getEmail()).isEqualTo("alice@example.com");
        assertThat(c.getCreatedAt()).isNotNull();
        verify(repository).save(any(Customer.class));
    }

    @Test
    void findById_throws_when_missing() {
        when(repository.findById(42L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.findById(42L))
                .isInstanceOf(CustomerNotFoundException.class)
                .hasMessageContaining("42");
    }

    @Test
    void findAll_returns_repo_results() {
        Customer a = new Customer("a", "a@x.com");
        when(repository.findAll()).thenReturn(List.of(a));

        assertThat(service.findAll()).containsExactly(a);
    }

    @Test
    void delete_throws_when_missing() {
        when(repository.existsById(7L)).thenReturn(false);

        assertThatThrownBy(() -> service.delete(7L))
                .isInstanceOf(CustomerNotFoundException.class);
        verify(repository, never()).deleteById(any());
    }
}

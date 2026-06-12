// Atomic operations on raw shared memory (the cross-process reader table
// lives in a mapped lock file). Swift's Synchronization.Atomic is a value
// type and cannot be placed into foreign memory; these C11 wrappers give
// defined cross-process semantics for the three operations the table needs.
#ifndef ADC_ATOMICS_H
#define ADC_ATOMICS_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

static inline uint64_t adc_load_acquire_u64(const volatile void *address) {
  return atomic_load_explicit(
      (const volatile _Atomic uint64_t *)address, memory_order_acquire);
}

static inline void adc_store_release_u64(volatile void *address, uint64_t value) {
  atomic_store_explicit(
      (volatile _Atomic uint64_t *)address, value, memory_order_release);
}

static inline bool adc_cas_acq_rel_u64(
    volatile void *address, uint64_t expected, uint64_t desired) {
  return atomic_compare_exchange_strong_explicit(
      (volatile _Atomic uint64_t *)address, &expected, desired,
      memory_order_acq_rel, memory_order_acquire);
}

#endif

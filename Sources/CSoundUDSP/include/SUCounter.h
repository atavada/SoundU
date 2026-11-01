#ifndef SOUNDU_COUNTER_H
#define SOUNDU_COUNTER_H

#include <stdatomic.h>
#include <stdint.h>

/// IO callback counter: incremented by the render thread after each render,
/// read from any thread. Real-time safe.
typedef struct {
    _Atomic uint64_t value;
} SUCounter;

static inline void su_counter_init(SUCounter *c) {
    atomic_init(&c->value, 0);
}

/// Release: everything the render did before this is visible to a reader
/// that observes the new value.
static inline void su_counter_increment(SUCounter *c) {
    atomic_fetch_add_explicit(&c->value, 1, memory_order_release);
}

static inline uint64_t su_counter_load(SUCounter *c) {
    return atomic_load_explicit(&c->value, memory_order_acquire);
}

#endif

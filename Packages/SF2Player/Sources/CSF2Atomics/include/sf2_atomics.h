// SPDX-License-Identifier: AGPL-3.0-or-later
#ifndef SF2_ATOMICS_H
#define SF2_ATOMICS_H
#include <stdint.h>
#include <string.h>

// Plain C11/GCC atomic builtins so Swift can do acquire/release on shared words from the
// real-time audio thread without locks, allocation or runtime calls (iOS 16: no Synchronization).
static inline int64_t sf2_atomic_load_i64(const int64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void sf2_atomic_store_i64(int64_t *p, int64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint64_t sf2_atomic_load_u64(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void sf2_atomic_store_u64(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }

// Single-producer/single-consumer level-meter queue. Each render callback publishes one complete
// block; the UI drains complete blocks so frame counts and sums always stay paired.
#define SF2_METER_QUEUE_CAPACITY 256
typedef struct {
    float peakL, peakR;
    double sumSqL, sumSqR;
    uint64_t frames;
} sf2_meter_block;

typedef struct {
    sf2_meter_block blocks[SF2_METER_QUEUE_CAPACITY];
    uint64_t writeIndex;
    uint64_t readIndex;
} sf2_meter;

static inline void sf2_meter_add(sf2_meter *m, float peakL, float peakR, double sumSqL, double sumSqR, uint64_t frames) {
    uint64_t write = __atomic_load_n(&m->writeIndex, __ATOMIC_RELAXED);
    uint64_t read = __atomic_load_n(&m->readIndex, __ATOMIC_ACQUIRE);
    if (write - read >= SF2_METER_QUEUE_CAPACITY) return; // Drop the whole block on overflow.
    sf2_meter_block *block = &m->blocks[write % SF2_METER_QUEUE_CAPACITY];
    block->peakL = peakL;
    block->peakR = peakR;
    block->sumSqL = sumSqL;
    block->sumSqR = sumSqR;
    block->frames = frames;
    __atomic_store_n(&m->writeIndex, write + 1, __ATOMIC_RELEASE);
}

static inline void sf2_meter_take(sf2_meter *m, float *peakL, float *peakR, double *sumSqL, double *sumSqR, uint64_t *frames) {
    uint64_t read = __atomic_load_n(&m->readIndex, __ATOMIC_RELAXED);
    uint64_t write = __atomic_load_n(&m->writeIndex, __ATOMIC_ACQUIRE);
    *peakL = 0;
    *peakR = 0;
    *sumSqL = 0;
    *sumSqR = 0;
    *frames = 0;
    while (read < write) {
        const sf2_meter_block *block = &m->blocks[read % SF2_METER_QUEUE_CAPACITY];
        if (block->peakL > *peakL) *peakL = block->peakL;
        if (block->peakR > *peakR) *peakR = block->peakR;
        *sumSqL += block->sumSqL;
        *sumSqR += block->sumSqR;
        *frames += block->frames;
        read++;
    }
    __atomic_store_n(&m->readIndex, read, __ATOMIC_RELEASE);
}

#endif

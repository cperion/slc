#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>

typedef struct Counter { uint64_t n; } Counter;
typedef struct SpinLock { bool held; } SpinLock;
typedef struct Shared { SpinLock lock; uint64_t total; } Shared;
typedef struct Ring { uint32_t head, tail, mask; uint32_t *slots; } Ring;

void bump(Counter *, uint32_t);
uint64_t read_counter(Counter *);
void add_locked(Shared *, uint32_t);
bool push(Ring *, uint32_t);
uint64_t drain(Ring *, uint32_t);
void publish(uint32_t *, uint32_t);

enum { THREADS = 4, TIMES = 100000, VALUES = 200000 };

static Counter counter;
static Shared shared;
static uint32_t slots[64];
static Ring ring = { 0, 0, 63, slots };

static void *bumper(void *arg) { (void)arg; bump(&counter, TIMES); return NULL; }
static void *locker(void *arg) { (void)arg; add_locked(&shared, TIMES); return NULL; }
static void *producer(void *arg) {
    (void)arg;
    for (uint32_t v = 1; v <= VALUES; v++) while (!push(&ring, v)) { }
    return NULL;
}
static uint64_t drained;
static void *consumer(void *arg) { (void)arg; drained = drain(&ring, VALUES); return NULL; }

int main(void) {
    pthread_t t[THREADS];
    for (int i = 0; i < THREADS; i++) pthread_create(&t[i], NULL, bumper, NULL);
    for (int i = 0; i < THREADS; i++) pthread_join(t[i], NULL);
    assert(read_counter(&counter) == (uint64_t)THREADS * TIMES);

    for (int i = 0; i < THREADS; i++) pthread_create(&t[i], NULL, locker, NULL);
    for (int i = 0; i < THREADS; i++) pthread_join(t[i], NULL);
    assert(shared.total == (uint64_t)THREADS * TIMES && !shared.lock.held);

    pthread_t p, c;
    pthread_create(&c, NULL, consumer, NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(c, NULL);
    assert(drained == (uint64_t)VALUES * (VALUES + 1) / 2);

    uint32_t head = 0;
    publish(&head, 9);
    assert(head == 9);
    puts("atomics: ok");
    return 0;
}

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
typedef struct Counter { uint32_t total; uint32_t calls; } Counter;
uint32_t bump(uint32_t n);
uint32_t bump_local(uint32_t n);
uint32_t read_seed(void);
uint32_t record(uint32_t n);
uint32_t apply(uint32_t (*f)(uint32_t), uint32_t x);
uint32_t (*pick(uint32_t which))(uint32_t);
void fill(void);
uint32_t through(uint32_t which, uint32_t x);

static uint32_t triple(uint32_t x) { return x * 3; }
static uint32_t local_seen;
static void *thread(void *arg) {
    (void)arg;
    local_seen = bump_local(5);   /* its own copy: starts at zero */
    return 0;
}

int main(void) {
    assert(bump(2) == 2 && bump(3) == 5);
    assert(read_seed() == 100);
    assert(record(4) == 4001 && record(6) == 10002);
    assert(bump_local(7) == 7);
    pthread_t th;
    assert(pthread_create(&th, 0, thread, 0) == 0);
    assert(pthread_join(th, 0) == 0);
    assert(local_seen == 5);
    assert(bump_local(1) == 8);   /* the main thread's copy is untouched */
    assert(apply(triple, 7) == 21);
    assert(pick(0)(6) == 12 && pick(1)(6) == 36 && pick(2) == 0);
    fill();
    assert(through(0, 5) == 10 && through(1, 5) == 25);
    return 0;
}

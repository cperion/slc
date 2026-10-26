#include <stdio.h>
#include <stdint.h>
#include <string.h>
typedef struct U8Slice { uint8_t *ptr; uint32_t len; } U8Slice;
typedef struct Stats { uint32_t rows; int64_t sum, min, max; } Stats;
Stats price_stats(U8Slice rows);
int main(void) {
    /* the rows of examples/data/sales.csv, after its header */
    char rows[] = "2026-10-01,Paris,12.50,3\n2026-10-01,Lyon,9.99,10\n2026-10-02,Paris,-1.25,1\n"
                  "2026-10-02,Lille,100.00,2\n2026-10-03,Nice,7.05,40\n";
    U8Slice s = { (uint8_t *)rows, (uint32_t)strlen(rows) };
    Stats st = price_stats(s);
    printf("csv: %u rows, sum %lld, min %lld, max %lld\n", st.rows, (long long)st.sum, (long long)st.min,
           (long long)st.max);
    return !(st.rows == 5 && st.sum == 12829 && st.min == -125 && st.max == 10000);
}

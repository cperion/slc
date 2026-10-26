#include <assert.h>
#include <stdint.h>
#include <stdio.h>
int64_t duration_units(int64_t n);
int main(void) {
    assert(duration_units(0) == 0);
    assert(duration_units(7) == INT64_C(7007007007));
    assert(duration_units(-7) == -INT64_C(7007007007));
    puts("durations: known and dynamic SLC unit conversions passed");
    return 0;
}

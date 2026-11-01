#include <stdint.h>
#include <stdio.h>
extern int32_t main_(int32_t, char **);
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s /path/to/font.ttf\n", argv[0]);
        return 2;
    }
    return main_(argc, argv);
}

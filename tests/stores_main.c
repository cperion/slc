#include <assert.h>
#include <stdio.h>
#include "slc_rt.h"

typedef struct Node { uint32_t value; } Node;
typedef slc_id NodeId;
typedef struct Graph { slc_store nodes; } Graph;

NodeId insert_double(Graph *graph, uint32_t value);
uint32_t run(uint32_t), churn(uint32_t), digits(uint32_t), sum_depths(uint32_t);
void populate_double(Graph *g, uint32_t n);

int main(void) {
    assert(run(0) == 0 && run(10) == 10 && run(1000) == 1000);
    /* every export gives its data stack back */
    assert(slc_gs_top(0) == 0);
    assert(churn(5) == 7);
    assert(digits(0) == 0 && digits(7) == 1 && digits(1234567) == 7 && digits(4294967295u) == 10);
    assert(sum_depths(10) == 11);
    assert(slc_gs_top(0) == 0);

    /* a store built by C, filled through the exported words */
    Graph g;
    g.nodes = slc_store_new(3);
    populate_double(&g, 4);
    NodeId id = insert_double(&g, 21);
    assert(g.nodes.live == 5 && id.slot == 4 && id.gen == 1 && id.token == g.nodes.token);
    slc_release(3, g.nodes.base);
    puts("stores: ok");
    return 0;
}

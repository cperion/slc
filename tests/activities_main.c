#include <assert.h>
#include <stdio.h>
#include "slc_rt.h"

typedef struct Document { uint32_t length, cursor, edits; } Document;
typedef struct Node { uint32_t value, weight; } Node;
typedef slc_id NodeId;
typedef struct Graph { slc_store nodes; } Graph;

void type_text(Document *, uint32_t);
uint32_t back_and_forth(Document *), fresh_length(uint32_t), evens(uint32_t), roundtrip(uint32_t);
uint32_t survives_growth(uint32_t n, bool flip);
void double_node(Graph *, NodeId);
int32_t shift(int32_t, int32_t);
uint32_t use_logged(uint32_t, uint32_t), to_base(uint32_t, uint32_t);
void import_rows(Document *, uint32_t);
uint32_t clamp_cb(uint32_t);
typedef struct Vec { double x, y; } Vec;
typedef struct Terminal { uint32_t width, drawn; } Terminal;
double squared(Vec), norm2(Vec);
uint32_t session(Terminal *, uint32_t);

static uint32_t logs[8], nlogs, traces[8], ntraces;
void log_call(uint32_t n) { logs[nlogs++] = n; }
void trace(uint32_t t) { traces[ntraces++] = t; }

int main(void) {
    Document d = { 10, 2, 0 };
    type_text(&d, 1);            /* insert 1 (cursor 3), move left (2), 2 > 3? no */
    assert(d.length == 11 && d.cursor == 2 && d.edits == 1);
    type_text(&d, 5);            /* cursor 7, left 6, > 3: insert 1 -> 7 */
    assert(d.length == 17 && d.cursor == 7 && d.edits == 3);
    assert(back_and_forth(&d) == 1 && d.cursor == 6);
    Document z = { 0, 0, 0 };
    assert(back_and_forth(&z) == 0 && z.cursor == 0);
    assert(fresh_length(5) == 702);
    assert(evens(0) == 0 && evens(1) == 0 && evens(10) == 5 && evens(11) == 5);
    assert(roundtrip(3) == 122);
    assert(survives_growth(5000, false) == 6);
    assert(survives_growth(5000, true) == 9);
    assert(slc_gs_top(0) == 0);
    assert(shift(1, 2) == 602 && shift(-7, 3) == -197);
    assert(use_logged(4, 5) == 8 + 10 && nlogs == 2 && logs[0] == 1 && logs[1] == 3);
    assert(to_base(2, 3) == 3002000);
    Document e = { 0, 0, 0 };
    import_rows(&e, 4);
    assert(e.length == 4 && e.edits == 1);
    assert(ntraces == 5 && traces[0] == 1 && traces[1] == 2 && traces[2] == 102 && traces[3] == 101 && traces[4] == 9);
    assert(clamp_cb(4) == 5 && clamp_cb(15) == 6 && clamp_cb(10) == 11);
    { Vec v = { 3.0, 4.0 }; assert(squared(v) == 25.0 && norm2(v) == 100.0); }
    { Terminal t = { 80, 10 }; assert(session(&t, 5) == 64 && t.drawn == 16); }
    puts("activities: ok");
    return 0;
}

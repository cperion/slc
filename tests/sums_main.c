#include <assert.h>
#include <stdio.h>
#include "slc_rt.h"

typedef struct Circle { uint32_t radius; } Circle;
typedef struct Rect { uint32_t width, height; } Rect;
enum { Shape_circle = 0, Shape_dot = 1, Shape_rect = 2 };
typedef struct Shape { uint32_t tag; union { Circle circle; Rect rect; } as; } Shape;
enum { Opt_none = 0, Opt_some = 1 };
typedef struct Opt { uint32_t tag; union { uint32_t some; } as; } Opt;
enum { Direction_left = 0, Direction_right = 1 };
typedef struct Direction { uint32_t tag; } Direction;
enum { Command_insert = 0, Command_move = 1, Command_undo = 2 };
typedef struct Command { uint32_t tag; union { uint32_t insert; Direction move; } as; } Command;
typedef struct Editor { uint32_t cursor, length, undos; } Editor;
typedef struct Token { Opt kind; uint32_t at; } Token;
enum { Small_dot = 0, Small_num = 1 };
typedef struct Small { uint32_t tag; union { uint32_t num; } as; } Small;
uint32_t num_or_zero(Small), always_one(Small);

uint32_t area(Shape), strip(uint32_t), pick(bool, uint32_t), demo(uint32_t), token_value(Token);
void apply(Editor *, Command), run_script(Editor *);

int main(void) {
    Shape c = { .tag = Shape_circle, .as.circle = { 2 } };
    Shape r = { .tag = Shape_rect, .as.rect = { 4, 5 } };
    Shape d = { .tag = Shape_dot };
    assert(area(c) == 12 && area(r) == 20 && area(d) == 0);
    assert(strip(9) == 9);
    assert(pick(true, 3) == 3 && pick(false, 3) == 7);

    Editor e = { 0, 0, 0 };
    apply(&e, (Command){ .tag = Command_insert, .as.insert = 4 });
    apply(&e, (Command){ .tag = Command_move, .as.move = { Direction_left } });
    apply(&e, (Command){ .tag = Command_move, .as.move = { Direction_right } });
    apply(&e, (Command){ .tag = Command_move, .as.move = { Direction_right } });
    apply(&e, (Command){ .tag = Command_undo });
    assert(e.cursor == 4 && e.length == 4 && e.undos == 1);

    /* the script: insert 5, left, left, undo, insert 2 */
    Editor s = { 0, 0, 0 };
    run_script(&s);
    assert(s.cursor == 5 && s.length == 7 && s.undos == 1);
    Editor s2 = { 0, 0, 0 };
    apply(&s2, (Command){ .tag = Command_insert, .as.insert = 5 });
    apply(&s2, (Command){ .tag = Command_move, .as.move = { Direction_left } });
    apply(&s2, (Command){ .tag = Command_move, .as.move = { Direction_left } });
    apply(&s2, (Command){ .tag = Command_undo });
    apply(&s2, (Command){ .tag = Command_insert, .as.insert = 2 });
    assert(s2.cursor == s.cursor && s2.length == s.length && s2.undos == s.undos);

    /* insert n, left, undo, right -> cursor n, length n, undos 1 */
    assert(demo(3) == 300 + 30 + 1 && demo(0) == 1);
    assert(slc_gs_top(0) == 0);

    Token t1 = { { .tag = Opt_some, .as.some = 5 }, 10 };
    Token t2 = { { .tag = Opt_none }, 10 };
    assert(token_value(t1) == 15 && token_value(t2) == 10);
    Small sd = { .tag = Small_dot }, sn = { .tag = Small_num, .as.num = 8 };
    assert(num_or_zero(sd) == 0 && num_or_zero(sn) == 8 && always_one(sd) == 1 && always_one(sn) == 1);
    puts("sums: ok");
    return 0;
}

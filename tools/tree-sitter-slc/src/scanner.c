// GPL-3.0-or-later. See ../../../COPYING.
#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

enum { LONG_STRING, LONG_COMMENT, NAME_ARGUMENT, ENDALL, IMPLICIT_END, ERROR_SENTINEL, ENDALL_RESET };
typedef struct { bool endall; uint32_t column; int32_t next; } Scanner;
void *tree_sitter_slc_external_scanner_create(void) { return calloc(1, sizeof(Scanner)); }
void tree_sitter_slc_external_scanner_destroy(void *p) { free(p); }
unsigned tree_sitter_slc_external_scanner_serialize(void *p, char *b) { memcpy(b, p, sizeof(Scanner)); return sizeof(Scanner); }
void tree_sitter_slc_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  memset(p, 0, sizeof(Scanner)); if (n == sizeof(Scanner)) memcpy(p, b, n);
}
static void advance(TSLexer *l) { l->advance(l, false); }
static bool name_start(int32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool name_char(int32_t c) { return name_start(c) || (c >= '0' && c <= '9'); }
bool tree_sitter_slc_external_scanner_scan(void *p, TSLexer *l, const bool *valid) {
  Scanner *s = p;
  if (valid[ERROR_SENTINEL]) return false;
  // One endall can close several adjacent untyped lambdas. Emit their extra
  // closers only at that exact boundary; the grammar excludes typed words.
  if (s->endall && s->column == l->get_column(l) && s->next == l->lookahead && valid[IMPLICIT_END]) {
    l->mark_end(l); l->result_symbol = IMPLICIT_END; return true;
  }
  // Persist clearing the endall state. Failed scans do not update Tree-sitter's
  // serialized state, so merely clearing the flag before returning false would
  // allow it to reappear at a later token with the same column.
  if (s->endall && valid[ENDALL_RESET]) {
    s->endall = false; l->mark_end(l); l->result_symbol = ENDALL_RESET; return true;
  }
  // Unlike literal arguments, a juxtaposed name must stay on the same line.
  // Scan it externally so skipped whitespace cannot erase that distinction.
  bool same_line = l->get_column(l) > 0;
  bool space = false;
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\n' || l->lookahead == '\r') {
    space = true;
    if (l->lookahead == '\n' || l->lookahead == '\r') same_line = false;
    l->advance(l, true);
  }
  if ((valid[ENDALL] || (valid[NAME_ARGUMENT] && same_line && space)) && name_start(l->lookahead)) {
    char name[128]; unsigned n = 0;
    while (name_char(l->lookahead)) {
      if (n < sizeof(name) - 1) name[n++] = (char)l->lookahead;
      advance(l);
    }
    name[n] = 0;
    if (valid[ENDALL] && !strcmp(name, "endall")) {
      s->endall = true; s->column = l->get_column(l); s->next = l->lookahead;
      l->mark_end(l); l->result_symbol = ENDALL; return true;
    }
    if (!valid[NAME_ARGUMENT] || !same_line || !space) return false;
    const char *keywords[] = {"and", "break", "continue", "do", "else", "elseif", "end", "endall", "export", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "struct", "then", "true", "until", "while"};
    for (unsigned i = 0; i < sizeof(keywords)/sizeof(*keywords); ++i) if (!strcmp(name, keywords[i])) return false;
    l->mark_end(l); l->result_symbol = NAME_ARGUMENT; return true;
  }
  bool comment = l->lookahead == '-';
  if (comment) {
    if (!valid[LONG_COMMENT]) return false;
    advance(l); if (l->lookahead != '-') return false; advance(l);
  } else if (!valid[LONG_STRING]) return false;
  if (l->lookahead != '[') return false;
  advance(l);
  unsigned equals = 0;
  while (l->lookahead == '=') { ++equals; advance(l); }
  if (l->lookahead != '[') return false;
  advance(l);
  while (!l->eof(l)) {
    if (l->lookahead != ']') { advance(l); continue; }
    advance(l);
    unsigned n = 0;
    while (l->lookahead == '=') { ++n; advance(l); }
    if (n == equals && l->lookahead == ']') {
      advance(l); l->mark_end(l); l->result_symbol = comment ? LONG_COMMENT : LONG_STRING; return true;
    }
  }
  return false;
}

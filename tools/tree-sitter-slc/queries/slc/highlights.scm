; GPL-3.0-or-later. See ../../../../COPYING.
(identifier) @variable
(comment) @comment
(string) @string
(escape_sequence) @string.escape
(number) @number
(boolean) @boolean
(nil) @constant.builtin

["local" "struct" "export" "goto"] @keyword
["do" "function" "end" "endall"] @keyword.function
["if" "then" "elseif" "else"] @keyword.conditional
["for" "in" "while" "repeat" "until" "break" "continue"] @keyword.repeat
"return" @keyword.return
["and" "or" "not"] @keyword.operator
; `call f(x)` parses as an application of a name `call`; it is the keyword
((call_expression function: (identifier) @keyword) (#eq? @keyword "call"))
["+" "-" "*" "/" "%" "^" "#" ".." "..." "==" "~=" "<" ">" "<=" ">=" "="] @operator
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" ":" "." "::"] @punctuation.delimiter

(type_annotation (identifier) @type)
(type_call (identifier) @type)
(type_member (identifier) @type)
(type_application (identifier) @type)
(parameter (identifier) @variable.parameter)
(member_expression member: (identifier) @variable.member)
(header_member member: (identifier) @variable.member)
(field (identifier) @variable.member ["=" ":"])
(field (identifier) ":" (identifier) @type)
(function_name (identifier) @function)
(handler name: (identifier) @function)
(call_expression function: (identifier) @function.call)
(call_expression function: (member_expression member: (identifier) @function.call))
(call_expression method: (identifier) @function.method.call)
(header_call function: (identifier) @function.call)
(header_call method: (identifier) @function.method.call)
(local_declaration (binding name: (identifier) @function) "=" (lambda))

((identifier) @type.builtin
 (#any-of? @type.builtin "I8" "I16" "I32" "I64" "U8" "U16" "U32" "U64" "F32" "F64" "Bool" "Unit" "Str" "CString" "Chars" "Text" "Array" "Ref" "Ptr" "Slice" "Store" "Id" "Grow" "Atomic"))

-- libgccjit's API for LuaJIT's FFI: libgccjit.h (GCC 13) preprocessed, from its
-- first declaration on. Regenerate: echo '#include <libgccjit.h>' | gcc -E -P - (then cut).
return [==[
typedef struct _IO_FILE FILE;
typedef struct gcc_jit_context gcc_jit_context;
typedef struct gcc_jit_result gcc_jit_result;
typedef struct gcc_jit_object gcc_jit_object;
typedef struct gcc_jit_location gcc_jit_location;
typedef struct gcc_jit_type gcc_jit_type;
typedef struct gcc_jit_field gcc_jit_field;
typedef struct gcc_jit_struct gcc_jit_struct;
typedef struct gcc_jit_function_type gcc_jit_function_type;
typedef struct gcc_jit_vector_type gcc_jit_vector_type;
typedef struct gcc_jit_function gcc_jit_function;
typedef struct gcc_jit_block gcc_jit_block;
typedef struct gcc_jit_rvalue gcc_jit_rvalue;
typedef struct gcc_jit_lvalue gcc_jit_lvalue;
typedef struct gcc_jit_param gcc_jit_param;
typedef struct gcc_jit_case gcc_jit_case;
typedef struct gcc_jit_extended_asm gcc_jit_extended_asm;
extern gcc_jit_context *
gcc_jit_context_acquire (void);
extern void
gcc_jit_context_release (gcc_jit_context *ctxt);
enum gcc_jit_str_option
{
  GCC_JIT_STR_OPTION_PROGNAME,
  GCC_JIT_NUM_STR_OPTIONS
};
enum gcc_jit_int_option
{
  GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL,
  GCC_JIT_NUM_INT_OPTIONS
};
enum gcc_jit_bool_option
{
  GCC_JIT_BOOL_OPTION_DEBUGINFO,
  GCC_JIT_BOOL_OPTION_DUMP_INITIAL_TREE,
  GCC_JIT_BOOL_OPTION_DUMP_INITIAL_GIMPLE,
  GCC_JIT_BOOL_OPTION_DUMP_GENERATED_CODE,
  GCC_JIT_BOOL_OPTION_DUMP_SUMMARY,
  GCC_JIT_BOOL_OPTION_DUMP_EVERYTHING,
  GCC_JIT_BOOL_OPTION_SELFCHECK_GC,
  GCC_JIT_BOOL_OPTION_KEEP_INTERMEDIATES,
  GCC_JIT_NUM_BOOL_OPTIONS
};
extern void
gcc_jit_context_set_str_option (gcc_jit_context *ctxt,
    enum gcc_jit_str_option opt,
    const char *value);
extern void
gcc_jit_context_set_int_option (gcc_jit_context *ctxt,
    enum gcc_jit_int_option opt,
    int value);
extern void
gcc_jit_context_set_bool_option (gcc_jit_context *ctxt,
     enum gcc_jit_bool_option opt,
     int value);
extern void
gcc_jit_context_set_bool_allow_unreachable_blocks (gcc_jit_context *ctxt,
         int bool_value);
extern void
gcc_jit_context_set_bool_print_errors_to_stderr (gcc_jit_context *ctxt,
       int enabled);
extern void
gcc_jit_context_set_bool_use_external_driver (gcc_jit_context *ctxt,
           int bool_value);
extern void
gcc_jit_context_add_command_line_option (gcc_jit_context *ctxt,
      const char *optname);
extern void
gcc_jit_context_add_driver_option (gcc_jit_context *ctxt,
       const char *optname);
extern gcc_jit_result *
gcc_jit_context_compile (gcc_jit_context *ctxt);
enum gcc_jit_output_kind
{
  GCC_JIT_OUTPUT_KIND_ASSEMBLER,
  GCC_JIT_OUTPUT_KIND_OBJECT_FILE,
  GCC_JIT_OUTPUT_KIND_DYNAMIC_LIBRARY,
  GCC_JIT_OUTPUT_KIND_EXECUTABLE
};
extern void
gcc_jit_context_compile_to_file (gcc_jit_context *ctxt,
     enum gcc_jit_output_kind output_kind,
     const char *output_path);
extern void
gcc_jit_context_dump_to_file (gcc_jit_context *ctxt,
         const char *path,
         int update_locations);
extern void
gcc_jit_context_set_logfile (gcc_jit_context *ctxt,
        FILE *logfile,
        int flags,
        int verbosity);
extern const char *
gcc_jit_context_get_first_error (gcc_jit_context *ctxt);
extern const char *
gcc_jit_context_get_last_error (gcc_jit_context *ctxt);
extern void *
gcc_jit_result_get_code (gcc_jit_result *result,
    const char *funcname);
extern void *
gcc_jit_result_get_global (gcc_jit_result *result,
      const char *name);
extern void
gcc_jit_result_release (gcc_jit_result *result);
extern gcc_jit_context *
gcc_jit_object_get_context (gcc_jit_object *obj);
extern const char *
gcc_jit_object_get_debug_string (gcc_jit_object *obj);
extern gcc_jit_location *
gcc_jit_context_new_location (gcc_jit_context *ctxt,
         const char *filename,
         int line,
         int column);
extern gcc_jit_object *
gcc_jit_location_as_object (gcc_jit_location *loc);
extern gcc_jit_object *
gcc_jit_type_as_object (gcc_jit_type *type);
enum gcc_jit_types
{
  GCC_JIT_TYPE_VOID,
  GCC_JIT_TYPE_VOID_PTR,
  GCC_JIT_TYPE_BOOL,
  GCC_JIT_TYPE_CHAR,
  GCC_JIT_TYPE_SIGNED_CHAR,
  GCC_JIT_TYPE_UNSIGNED_CHAR,
  GCC_JIT_TYPE_SHORT,
  GCC_JIT_TYPE_UNSIGNED_SHORT,
  GCC_JIT_TYPE_INT,
  GCC_JIT_TYPE_UNSIGNED_INT,
  GCC_JIT_TYPE_LONG,
  GCC_JIT_TYPE_UNSIGNED_LONG,
  GCC_JIT_TYPE_LONG_LONG,
  GCC_JIT_TYPE_UNSIGNED_LONG_LONG,
  GCC_JIT_TYPE_FLOAT,
  GCC_JIT_TYPE_DOUBLE,
  GCC_JIT_TYPE_LONG_DOUBLE,
  GCC_JIT_TYPE_CONST_CHAR_PTR,
  GCC_JIT_TYPE_SIZE_T,
  GCC_JIT_TYPE_FILE_PTR,
  GCC_JIT_TYPE_COMPLEX_FLOAT,
  GCC_JIT_TYPE_COMPLEX_DOUBLE,
  GCC_JIT_TYPE_COMPLEX_LONG_DOUBLE,
  GCC_JIT_TYPE_UINT8_T,
  GCC_JIT_TYPE_UINT16_T,
  GCC_JIT_TYPE_UINT32_T,
  GCC_JIT_TYPE_UINT64_T,
  GCC_JIT_TYPE_UINT128_T,
  GCC_JIT_TYPE_INT8_T,
  GCC_JIT_TYPE_INT16_T,
  GCC_JIT_TYPE_INT32_T,
  GCC_JIT_TYPE_INT64_T,
  GCC_JIT_TYPE_INT128_T
};
extern gcc_jit_type *
gcc_jit_context_get_type (gcc_jit_context *ctxt,
     enum gcc_jit_types type_);
extern gcc_jit_type *
gcc_jit_context_get_int_type (gcc_jit_context *ctxt,
         int num_bytes, int is_signed);
extern gcc_jit_type *
gcc_jit_type_get_pointer (gcc_jit_type *type);
extern gcc_jit_type *
gcc_jit_type_get_const (gcc_jit_type *type);
extern gcc_jit_type *
gcc_jit_type_get_volatile (gcc_jit_type *type);
extern int
gcc_jit_compatible_types (gcc_jit_type *ltype,
     gcc_jit_type *rtype);
extern ssize_t
gcc_jit_type_get_size (gcc_jit_type *type);
extern gcc_jit_type *
gcc_jit_context_new_array_type (gcc_jit_context *ctxt,
    gcc_jit_location *loc,
    gcc_jit_type *element_type,
    int num_elements);
extern gcc_jit_field *
gcc_jit_context_new_field (gcc_jit_context *ctxt,
      gcc_jit_location *loc,
      gcc_jit_type *type,
      const char *name);
extern gcc_jit_field *
gcc_jit_context_new_bitfield (gcc_jit_context *ctxt,
         gcc_jit_location *loc,
         gcc_jit_type *type,
         int width,
         const char *name);
extern gcc_jit_object *
gcc_jit_field_as_object (gcc_jit_field *field);
extern gcc_jit_struct *
gcc_jit_context_new_struct_type (gcc_jit_context *ctxt,
     gcc_jit_location *loc,
     const char *name,
     int num_fields,
     gcc_jit_field **fields);
extern gcc_jit_struct *
gcc_jit_context_new_opaque_struct (gcc_jit_context *ctxt,
       gcc_jit_location *loc,
       const char *name);
extern gcc_jit_type *
gcc_jit_struct_as_type (gcc_jit_struct *struct_type);
extern void
gcc_jit_struct_set_fields (gcc_jit_struct *struct_type,
      gcc_jit_location *loc,
      int num_fields,
      gcc_jit_field **fields);
extern gcc_jit_field *
gcc_jit_struct_get_field (gcc_jit_struct *struct_type,
      size_t index);
extern size_t
gcc_jit_struct_get_field_count (gcc_jit_struct *struct_type);
extern gcc_jit_type *
gcc_jit_context_new_union_type (gcc_jit_context *ctxt,
    gcc_jit_location *loc,
    const char *name,
    int num_fields,
    gcc_jit_field **fields);
extern gcc_jit_type *
gcc_jit_context_new_function_ptr_type (gcc_jit_context *ctxt,
           gcc_jit_location *loc,
           gcc_jit_type *return_type,
           int num_params,
           gcc_jit_type **param_types,
           int is_variadic);
extern gcc_jit_param *
gcc_jit_context_new_param (gcc_jit_context *ctxt,
      gcc_jit_location *loc,
      gcc_jit_type *type,
      const char *name);
extern gcc_jit_object *
gcc_jit_param_as_object (gcc_jit_param *param);
extern gcc_jit_lvalue *
gcc_jit_param_as_lvalue (gcc_jit_param *param);
extern gcc_jit_rvalue *
gcc_jit_param_as_rvalue (gcc_jit_param *param);
enum gcc_jit_function_kind
{
  GCC_JIT_FUNCTION_EXPORTED,
  GCC_JIT_FUNCTION_INTERNAL,
  GCC_JIT_FUNCTION_IMPORTED,
  GCC_JIT_FUNCTION_ALWAYS_INLINE
};
enum gcc_jit_tls_model
{
  GCC_JIT_TLS_MODEL_NONE,
  GCC_JIT_TLS_MODEL_GLOBAL_DYNAMIC,
  GCC_JIT_TLS_MODEL_LOCAL_DYNAMIC,
  GCC_JIT_TLS_MODEL_INITIAL_EXEC,
  GCC_JIT_TLS_MODEL_LOCAL_EXEC,
};
extern gcc_jit_function *
gcc_jit_context_new_function (gcc_jit_context *ctxt,
         gcc_jit_location *loc,
         enum gcc_jit_function_kind kind,
         gcc_jit_type *return_type,
         const char *name,
         int num_params,
         gcc_jit_param **params,
         int is_variadic);
extern gcc_jit_function *
gcc_jit_context_get_builtin_function (gcc_jit_context *ctxt,
          const char *name);
extern gcc_jit_object *
gcc_jit_function_as_object (gcc_jit_function *func);
extern gcc_jit_param *
gcc_jit_function_get_param (gcc_jit_function *func, int index);
extern void
gcc_jit_function_dump_to_dot (gcc_jit_function *func,
         const char *path);
extern gcc_jit_block *
gcc_jit_function_new_block (gcc_jit_function *func,
       const char *name);
extern gcc_jit_object *
gcc_jit_block_as_object (gcc_jit_block *block);
extern gcc_jit_function *
gcc_jit_block_get_function (gcc_jit_block *block);
enum gcc_jit_global_kind
{
  GCC_JIT_GLOBAL_EXPORTED,
  GCC_JIT_GLOBAL_INTERNAL,
  GCC_JIT_GLOBAL_IMPORTED
};
extern gcc_jit_lvalue *
gcc_jit_context_new_global (gcc_jit_context *ctxt,
       gcc_jit_location *loc,
       enum gcc_jit_global_kind kind,
       gcc_jit_type *type,
       const char *name);
extern gcc_jit_rvalue *
gcc_jit_context_new_struct_constructor (gcc_jit_context *ctxt,
     gcc_jit_location *loc,
     gcc_jit_type *type,
     size_t num_values,
     gcc_jit_field **fields,
     gcc_jit_rvalue **values);
extern gcc_jit_rvalue *
gcc_jit_context_new_union_constructor (gcc_jit_context *ctxt,
           gcc_jit_location *loc,
           gcc_jit_type *type,
           gcc_jit_field *field,
           gcc_jit_rvalue *value);
extern gcc_jit_rvalue *
gcc_jit_context_new_array_constructor (gcc_jit_context *ctxt,
           gcc_jit_location *loc,
           gcc_jit_type *type,
           size_t num_values,
           gcc_jit_rvalue **values);
extern gcc_jit_lvalue *
gcc_jit_global_set_initializer_rvalue (gcc_jit_lvalue *global,
           gcc_jit_rvalue *init_value);
extern gcc_jit_lvalue *
gcc_jit_global_set_initializer (gcc_jit_lvalue *global,
    const void *blob,
    size_t num_bytes);
extern gcc_jit_object *
gcc_jit_lvalue_as_object (gcc_jit_lvalue *lvalue);
extern gcc_jit_rvalue *
gcc_jit_lvalue_as_rvalue (gcc_jit_lvalue *lvalue);
extern gcc_jit_object *
gcc_jit_rvalue_as_object (gcc_jit_rvalue *rvalue);
extern gcc_jit_type *
gcc_jit_rvalue_get_type (gcc_jit_rvalue *rvalue);
extern gcc_jit_rvalue *
gcc_jit_context_new_rvalue_from_int (gcc_jit_context *ctxt,
         gcc_jit_type *numeric_type,
         int value);
extern gcc_jit_rvalue *
gcc_jit_context_new_rvalue_from_long (gcc_jit_context *ctxt,
          gcc_jit_type *numeric_type,
          long value);
extern gcc_jit_rvalue *
gcc_jit_context_zero (gcc_jit_context *ctxt,
        gcc_jit_type *numeric_type);
extern gcc_jit_rvalue *
gcc_jit_context_one (gcc_jit_context *ctxt,
       gcc_jit_type *numeric_type);
extern gcc_jit_rvalue *
gcc_jit_context_new_rvalue_from_double (gcc_jit_context *ctxt,
     gcc_jit_type *numeric_type,
     double value);
extern gcc_jit_rvalue *
gcc_jit_context_new_rvalue_from_ptr (gcc_jit_context *ctxt,
         gcc_jit_type *pointer_type,
         void *value);
extern gcc_jit_rvalue *
gcc_jit_context_null (gcc_jit_context *ctxt,
        gcc_jit_type *pointer_type);
extern gcc_jit_rvalue *
gcc_jit_context_new_string_literal (gcc_jit_context *ctxt,
        const char *value);
enum gcc_jit_unary_op
{
  GCC_JIT_UNARY_OP_MINUS,
  GCC_JIT_UNARY_OP_BITWISE_NEGATE,
  GCC_JIT_UNARY_OP_LOGICAL_NEGATE,
  GCC_JIT_UNARY_OP_ABS
};
extern gcc_jit_rvalue *
gcc_jit_context_new_unary_op (gcc_jit_context *ctxt,
         gcc_jit_location *loc,
         enum gcc_jit_unary_op op,
         gcc_jit_type *result_type,
         gcc_jit_rvalue *rvalue);
enum gcc_jit_binary_op
{
  GCC_JIT_BINARY_OP_PLUS,
  GCC_JIT_BINARY_OP_MINUS,
  GCC_JIT_BINARY_OP_MULT,
  GCC_JIT_BINARY_OP_DIVIDE,
  GCC_JIT_BINARY_OP_MODULO,
  GCC_JIT_BINARY_OP_BITWISE_AND,
  GCC_JIT_BINARY_OP_BITWISE_XOR,
  GCC_JIT_BINARY_OP_BITWISE_OR,
  GCC_JIT_BINARY_OP_LOGICAL_AND,
  GCC_JIT_BINARY_OP_LOGICAL_OR,
  GCC_JIT_BINARY_OP_LSHIFT,
  GCC_JIT_BINARY_OP_RSHIFT
};
extern gcc_jit_rvalue *
gcc_jit_context_new_binary_op (gcc_jit_context *ctxt,
          gcc_jit_location *loc,
          enum gcc_jit_binary_op op,
          gcc_jit_type *result_type,
          gcc_jit_rvalue *a, gcc_jit_rvalue *b);
enum gcc_jit_comparison
{
  GCC_JIT_COMPARISON_EQ,
  GCC_JIT_COMPARISON_NE,
  GCC_JIT_COMPARISON_LT,
  GCC_JIT_COMPARISON_LE,
  GCC_JIT_COMPARISON_GT,
  GCC_JIT_COMPARISON_GE
};
extern gcc_jit_rvalue *
gcc_jit_context_new_comparison (gcc_jit_context *ctxt,
    gcc_jit_location *loc,
    enum gcc_jit_comparison op,
    gcc_jit_rvalue *a, gcc_jit_rvalue *b);
extern gcc_jit_rvalue *
gcc_jit_context_new_call (gcc_jit_context *ctxt,
     gcc_jit_location *loc,
     gcc_jit_function *func,
     int numargs , gcc_jit_rvalue **args);
extern gcc_jit_rvalue *
gcc_jit_context_new_call_through_ptr (gcc_jit_context *ctxt,
          gcc_jit_location *loc,
          gcc_jit_rvalue *fn_ptr,
          int numargs, gcc_jit_rvalue **args);
extern gcc_jit_rvalue *
gcc_jit_context_new_cast (gcc_jit_context *ctxt,
     gcc_jit_location *loc,
     gcc_jit_rvalue *rvalue,
     gcc_jit_type *type);
extern gcc_jit_rvalue *
gcc_jit_context_new_bitcast (gcc_jit_context *ctxt,
        gcc_jit_location *loc,
        gcc_jit_rvalue *rvalue,
        gcc_jit_type *type);
extern void
gcc_jit_lvalue_set_alignment (gcc_jit_lvalue *lvalue,
         unsigned bytes);
extern unsigned
gcc_jit_lvalue_get_alignment (gcc_jit_lvalue *lvalue);
extern gcc_jit_lvalue *
gcc_jit_context_new_array_access (gcc_jit_context *ctxt,
      gcc_jit_location *loc,
      gcc_jit_rvalue *ptr,
      gcc_jit_rvalue *index);
extern gcc_jit_lvalue *
gcc_jit_lvalue_access_field (gcc_jit_lvalue *struct_or_union,
        gcc_jit_location *loc,
        gcc_jit_field *field);
extern gcc_jit_rvalue *
gcc_jit_rvalue_access_field (gcc_jit_rvalue *struct_or_union,
        gcc_jit_location *loc,
        gcc_jit_field *field);
extern gcc_jit_lvalue *
gcc_jit_rvalue_dereference_field (gcc_jit_rvalue *ptr,
      gcc_jit_location *loc,
      gcc_jit_field *field);
extern gcc_jit_lvalue *
gcc_jit_rvalue_dereference (gcc_jit_rvalue *rvalue,
       gcc_jit_location *loc);
extern gcc_jit_rvalue *
gcc_jit_lvalue_get_address (gcc_jit_lvalue *lvalue,
       gcc_jit_location *loc);
extern void
gcc_jit_lvalue_set_tls_model (gcc_jit_lvalue *lvalue,
       enum gcc_jit_tls_model model);
extern void
gcc_jit_lvalue_set_link_section (gcc_jit_lvalue *lvalue,
       const char *section_name);
void
gcc_jit_lvalue_set_register_name (gcc_jit_lvalue *lvalue,
      const char *reg_name);
extern gcc_jit_lvalue *
gcc_jit_function_new_local (gcc_jit_function *func,
       gcc_jit_location *loc,
       gcc_jit_type *type,
       const char *name);
extern void
gcc_jit_block_add_eval (gcc_jit_block *block,
   gcc_jit_location *loc,
   gcc_jit_rvalue *rvalue);
extern void
gcc_jit_block_add_assignment (gcc_jit_block *block,
         gcc_jit_location *loc,
         gcc_jit_lvalue *lvalue,
         gcc_jit_rvalue *rvalue);
extern void
gcc_jit_block_add_assignment_op (gcc_jit_block *block,
     gcc_jit_location *loc,
     gcc_jit_lvalue *lvalue,
     enum gcc_jit_binary_op op,
     gcc_jit_rvalue *rvalue);
extern void
gcc_jit_block_add_comment (gcc_jit_block *block,
      gcc_jit_location *loc,
      const char *text);
extern void
gcc_jit_block_end_with_conditional (gcc_jit_block *block,
        gcc_jit_location *loc,
        gcc_jit_rvalue *boolval,
        gcc_jit_block *on_true,
        gcc_jit_block *on_false);
extern void
gcc_jit_block_end_with_jump (gcc_jit_block *block,
        gcc_jit_location *loc,
        gcc_jit_block *target);
extern void
gcc_jit_block_end_with_return (gcc_jit_block *block,
          gcc_jit_location *loc,
          gcc_jit_rvalue *rvalue);
extern void
gcc_jit_block_end_with_void_return (gcc_jit_block *block,
        gcc_jit_location *loc);
extern gcc_jit_case *
gcc_jit_context_new_case (gcc_jit_context *ctxt,
     gcc_jit_rvalue *min_value,
     gcc_jit_rvalue *max_value,
     gcc_jit_block *dest_block);
extern gcc_jit_object *
gcc_jit_case_as_object (gcc_jit_case *case_);
extern void
gcc_jit_block_end_with_switch (gcc_jit_block *block,
          gcc_jit_location *loc,
          gcc_jit_rvalue *expr,
          gcc_jit_block *default_block,
          int num_cases,
          gcc_jit_case **cases);
extern gcc_jit_context *
gcc_jit_context_new_child_context (gcc_jit_context *parent_ctxt);
extern void
gcc_jit_context_dump_reproducer_to_file (gcc_jit_context *ctxt,
      const char *path);
extern void
gcc_jit_context_enable_dump (gcc_jit_context *ctxt,
        const char *dumpname,
        char **out_ptr);
typedef struct gcc_jit_timer gcc_jit_timer;
extern gcc_jit_timer *
gcc_jit_timer_new (void);
extern void
gcc_jit_timer_release (gcc_jit_timer *timer);
extern void
gcc_jit_context_set_timer (gcc_jit_context *ctxt,
      gcc_jit_timer *timer);
extern gcc_jit_timer *
gcc_jit_context_get_timer (gcc_jit_context *ctxt);
extern void
gcc_jit_timer_push (gcc_jit_timer *timer,
      const char *item_name);
extern void
gcc_jit_timer_pop (gcc_jit_timer *timer,
     const char *item_name);
extern void
gcc_jit_timer_print (gcc_jit_timer *timer,
       FILE *f_out);
extern void
gcc_jit_rvalue_set_bool_require_tail_call (gcc_jit_rvalue *call,
        int require_tail_call);
extern gcc_jit_type *
gcc_jit_type_get_aligned (gcc_jit_type *type,
     size_t alignment_in_bytes);
extern gcc_jit_type *
gcc_jit_type_get_vector (gcc_jit_type *type, size_t num_units);
extern gcc_jit_rvalue *
gcc_jit_function_get_address (gcc_jit_function *fn,
         gcc_jit_location *loc);
extern gcc_jit_rvalue *
gcc_jit_context_new_rvalue_from_vector (gcc_jit_context *ctxt,
     gcc_jit_location *loc,
     gcc_jit_type *vec_type,
     size_t num_elements,
     gcc_jit_rvalue **elements);
extern int
gcc_jit_version_major (void);
extern int
gcc_jit_version_minor (void);
extern int
gcc_jit_version_patchlevel (void);
extern gcc_jit_extended_asm *
gcc_jit_block_add_extended_asm (gcc_jit_block *block,
    gcc_jit_location *loc,
    const char *asm_template);
extern gcc_jit_extended_asm *
gcc_jit_block_end_with_extended_asm_goto (gcc_jit_block *block,
       gcc_jit_location *loc,
       const char *asm_template,
       int num_goto_blocks,
       gcc_jit_block **goto_blocks,
       gcc_jit_block *fallthrough_block);
extern gcc_jit_object *
gcc_jit_extended_asm_as_object (gcc_jit_extended_asm *ext_asm);
extern void
gcc_jit_extended_asm_set_volatile_flag (gcc_jit_extended_asm *ext_asm,
     int flag);
extern void
gcc_jit_extended_asm_set_inline_flag (gcc_jit_extended_asm *ext_asm,
          int flag);
extern void
gcc_jit_extended_asm_add_output_operand (gcc_jit_extended_asm *ext_asm,
      const char *asm_symbolic_name,
      const char *constraint,
      gcc_jit_lvalue *dest);
extern void
gcc_jit_extended_asm_add_input_operand (gcc_jit_extended_asm *ext_asm,
     const char *asm_symbolic_name,
     const char *constraint,
     gcc_jit_rvalue *src);
extern void
gcc_jit_extended_asm_add_clobber (gcc_jit_extended_asm *ext_asm,
      const char *victim);
extern void
gcc_jit_context_add_top_level_asm (gcc_jit_context *ctxt,
       gcc_jit_location *loc,
       const char *asm_stmts);
extern gcc_jit_type *
gcc_jit_function_get_return_type (gcc_jit_function *func);
extern size_t
gcc_jit_function_get_param_count (gcc_jit_function *func);
extern gcc_jit_type *
gcc_jit_type_dyncast_array (gcc_jit_type *type);
extern int
gcc_jit_type_is_bool (gcc_jit_type *type);
extern gcc_jit_function_type *
gcc_jit_type_dyncast_function_ptr_type (gcc_jit_type *type);
extern gcc_jit_type *
gcc_jit_function_type_get_return_type (gcc_jit_function_type *function_type);
extern size_t
gcc_jit_function_type_get_param_count (gcc_jit_function_type *function_type);
extern gcc_jit_type *
gcc_jit_function_type_get_param_type (gcc_jit_function_type *function_type,
    size_t index);
extern int
gcc_jit_type_is_integral (gcc_jit_type *type);
extern gcc_jit_type *
gcc_jit_type_is_pointer (gcc_jit_type *type);
extern gcc_jit_vector_type *
gcc_jit_type_dyncast_vector (gcc_jit_type *type);
extern gcc_jit_struct *
gcc_jit_type_is_struct (gcc_jit_type *type);
extern size_t
gcc_jit_vector_type_get_num_units (gcc_jit_vector_type *vector_type);
extern gcc_jit_type *
gcc_jit_vector_type_get_element_type (gcc_jit_vector_type *vector_type);
extern gcc_jit_type *
gcc_jit_type_unqualified (gcc_jit_type *type);
]==]

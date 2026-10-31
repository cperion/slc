/* The only target-specific native marshaling mechanisms. No SLC operations. */
#include "offsets.inc"
.text
.globl cp_native_call
.type cp_native_call,@function
cp_native_call:
    .cfi_startproc
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp,-16
    movq %rsp,%rbp
    .cfi_def_cfa_register %rbp
    pushq %r12
    .cfi_offset %r12,-24
    pushq %r13
    .cfi_offset %r13,-32
    movq %rdi,%r12
    movq CP_STACK_SIZE(%r12),%rax
    addq $15,%rax
    andq $-16,%rax
    /* Probe every page instead of jumping across a native stack guard. The
     * construction-time planner bounds stack_size and its alignment addition. */
.Lallocate:
    cmpq $4096,%rax
    jb .Lremainder
    subq $4096,%rsp
    orq $0,(%rsp)
    subq $4096,%rax
    jmp .Lallocate
.Lremainder:
    subq %rax,%rsp
    orq $0,(%rsp)
    movq %rsp,%rdi
    movq CP_STACK_DATA(%r12),%rsi
    movq CP_STACK_SIZE(%r12),%rcx
    rep movsb
    movdqu CP_XMM+0(%r12),%xmm0
    movdqu CP_XMM+16(%r12),%xmm1
    movdqu CP_XMM+32(%r12),%xmm2
    movdqu CP_XMM+48(%r12),%xmm3
    movdqu CP_XMM+64(%r12),%xmm4
    movdqu CP_XMM+80(%r12),%xmm5
    movdqu CP_XMM+96(%r12),%xmm6
    movdqu CP_XMM+112(%r12),%xmm7
    movq CP_TARGET(%r12),%r11
    movzbl CP_VECTOR_COUNT(%r12),%eax
    movq CP_GPR+0(%r12),%rdi
    movq CP_GPR+8(%r12),%rsi
    movq CP_GPR+16(%r12),%rdx
    movq CP_GPR+24(%r12),%rcx
    movq CP_GPR+32(%r12),%r8
    movq CP_GPR+40(%r12),%r9
    call *%r11
    movq %rax,CP_RET_GPR+0(%r12)
    movq %rdx,CP_RET_GPR+8(%r12)
    movdqu %xmm0,CP_RET_XMM+0(%r12)
    movdqu %xmm1,CP_RET_XMM+16(%r12)
    leaq -16(%rbp),%rsp
    popq %r13
    popq %r12
    popq %rbp
    .cfi_def_cfa %rsp,8
    ret
    .cfi_endproc
.size cp_native_call,.-cp_native_call

/* R10 = immutable entry descriptor. Capture arguments before calling C. */
.globl cp_native_entry
.type cp_native_entry,@function
cp_native_entry:
    .cfi_startproc
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp,-16
    movq %rsp,%rbp
    .cfi_def_cfa_register %rbp
    subq $CP_IMAGE_SIZE,%rsp
    movq %rdi,CP_GPR+0(%rsp)
    movq %rsi,CP_GPR+8(%rsp)
    movq %rdx,CP_GPR+16(%rsp)
    movq %rcx,CP_GPR+24(%rsp)
    movq %r8,CP_GPR+32(%rsp)
    movq %r9,CP_GPR+40(%rsp)
    movdqu %xmm0,CP_XMM+0(%rsp)
    movdqu %xmm1,CP_XMM+16(%rsp)
    movdqu %xmm2,CP_XMM+32(%rsp)
    movdqu %xmm3,CP_XMM+48(%rsp)
    movdqu %xmm4,CP_XMM+64(%rsp)
    movdqu %xmm5,CP_XMM+80(%rsp)
    movdqu %xmm6,CP_XMM+96(%rsp)
    movdqu %xmm7,CP_XMM+112(%rsp)
    movb %al,CP_VECTOR_COUNT(%rsp)
    leaq 16(%rbp),%rax
    movq %rax,CP_STACK_DATA(%rsp)
    movq $0,CP_STACK_SIZE(%rsp)
    movq $0,CP_TARGET(%rsp)
    /* Unused result lanes are deterministic, even for void/one-lane results. */
    pxor %xmm0,%xmm0
    movdqu %xmm0,CP_RET_GPR(%rsp)
    movdqu %xmm0,CP_RET_XMM(%rsp)
    movdqu %xmm0,CP_RET_XMM+16(%rsp)
    movq %r10,%rdi
    movq %rsp,%rsi
    call cp_dispatch@PLT
    movq CP_RET_GPR+0(%rsp),%rax
    movq CP_RET_GPR+8(%rsp),%rdx
    movdqu CP_RET_XMM+0(%rsp),%xmm0
    movdqu CP_RET_XMM+16(%rsp),%xmm1
    movq %rbp,%rsp
    popq %rbp
    .cfi_def_cfa %rsp,8
    ret
    .cfi_endproc
.size cp_native_entry,.-cp_native_entry
.section .note.GNU-stack,"",@progbits

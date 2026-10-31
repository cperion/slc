#include "offsets.inc"
.text
/* Independent observer of the actual preserve_none parameter registers. */
.globl cp_test_capture
.type cp_test_capture,@function
cp_test_capture:
    movq CP_CTX_RESULT(%r12),%r10
    movq %r13,CP_BANK_I+0(%r10)
    movq %r14,CP_BANK_I+8(%r10)
    movq %r15,CP_BANK_I+16(%r10)
    movq %rdi,CP_BANK_I+24(%r10)
    movq %rsi,CP_BANK_I+32(%r10)
    movq %rdx,CP_BANK_I+40(%r10)
    movq %rcx,CP_BANK_I+48(%r10)
    movq %r8,CP_BANK_I+56(%r10)
    movq %r9,CP_BANK_I+64(%r10)
    movq %r11,CP_BANK_I+72(%r10)
    movq %rax,CP_BANK_I+80(%r10)
    movdqu %xmm0,CP_BANK_F+0(%r10)
    movdqu %xmm1,CP_BANK_F+16(%r10)
    movdqu %xmm2,CP_BANK_F+32(%r10)
    movdqu %xmm3,CP_BANK_F+48(%r10)
    movdqu %xmm4,CP_BANK_F+64(%r10)
    movdqu %xmm5,CP_BANK_F+80(%r10)
    movdqu %xmm6,CP_BANK_F+96(%r10)
    movdqu %xmm7,CP_BANK_F+112(%r10)
    ret
.size cp_test_capture,.-cp_test_capture

/* int cp_test_preserved(void (*fn)(void *), void *arg)
 * Preserve our caller's registers, then install independent sentinels. */
.globl cp_test_preserved
.type cp_test_preserved,@function
cp_test_preserved:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $24,%rsp
    movq %rdi,0(%rsp)
    movq %rsi,8(%rsp)
    movq $101,%rbp
    movq $102,%rbx
    movq $103,%r12
    movq $104,%r13
    movq $105,%r14
    movq $106,%r15
    movq 8(%rsp),%rdi
    call *0(%rsp)
    movl $1,%eax
    cmpq $101,%rbp
    jne .Lbad
    cmpq $102,%rbx
    jne .Lbad
    cmpq $103,%r12
    jne .Lbad
    cmpq $104,%r13
    jne .Lbad
    cmpq $105,%r14
    jne .Lbad
    cmpq $106,%r15
    jne .Lbad
    xorl %eax,%eax
.Lbad:
    addq $24,%rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.size cp_test_preserved,.-cp_test_preserved

.globl cp_test_stack_align
.type cp_test_stack_align,@function
cp_test_stack_align:
    movq %rsp,%rax
    andq $15,%rax
    ret
.size cp_test_stack_align,.-cp_test_stack_align
/* Force every SysV caller-clobbered lane to change. */
.globl cp_test_clobber
.type cp_test_clobber,@function
cp_test_clobber:
    movq $-1,%rdi
    movq $-1,%rsi
    movq $-1,%rdx
    movq $-1,%rcx
    movq $-1,%r8
    movq $-1,%r9
    movq $-1,%r10
    movq $-1,%r11
    pcmpeqb %xmm0,%xmm0
    pcmpeqb %xmm1,%xmm1
    pcmpeqb %xmm2,%xmm2
    pcmpeqb %xmm3,%xmm3
    pcmpeqb %xmm4,%xmm4
    pcmpeqb %xmm5,%xmm5
    pcmpeqb %xmm6,%xmm6
    pcmpeqb %xmm7,%xmm7
    pcmpeqb %xmm8,%xmm8
    pcmpeqb %xmm9,%xmm9
    pcmpeqb %xmm10,%xmm10
    pcmpeqb %xmm11,%xmm11
    pcmpeqb %xmm12,%xmm12
    pcmpeqb %xmm13,%xmm13
    pcmpeqb %xmm14,%xmm14
    pcmpeqb %xmm15,%xmm15
    movq $123456,%rax
    ret
.size cp_test_clobber,.-cp_test_clobber
.section .note.GNU-stack,"",@progbits

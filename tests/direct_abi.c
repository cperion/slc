#define _GNU_SOURCE
#include "abi.h"
#include <assert.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

extern cp_handler cp_test_capture;
extern int cp_test_preserved(void (*fn)(void *), void *arg);
extern uint64_t cp_test_stack_align(void);
extern uint64_t cp_test_clobber(void);
static unsigned checks;
#define CHECK(x) do { assert(x); ++checks; } while (0)

static cp_bank bank(void) {
    cp_bank b = {0};
    for (unsigned i=0;i<CP_NI;++i) b.i[i]=UINT64_C(0xc13579bdf0000000)+i*97;
    for (unsigned i=0;i<CP_NF;++i) {
        b.f[i][0]=UINT64_C(0x7ff8123412340000)+i;
        b.f[i][1]=UINT64_C(0xa512345678900000)+i*19;
    }
    return b;
}
static int bank_equal(const cp_bank *a,const cp_bank *b) {
    return !memcmp(a->i,b->i,sizeof a->i) && !memcmp(a->f,b->f,sizeof a->f);
}
static void CP_ABI finish(CP_PARAMS) {
    cp_bank b = {0}; CP_SAVE(b); memcpy(ctx->result,&b,sizeof b);
}
static void CP_ABI loop(CP_PARAMS) {
    if (i0 == 0) { CP_TAIL finish(CP_ARGS); }
    i1 += i0; --i0;
    CP_TAIL loop(CP_ARGS);
}
static void CP_ABI native_call(CP_PARAMS) {
    cp_bank saved = {0}; CP_SAVE(saved);
    cp_call_image *image = ctx->user;
    cp_native_call(image);
    saved.i[0] = image->ret_gpr[0];
    CP_TAIL finish(CP_FROM(ctx,saved));
}
static void CP_ABI add_inputs(CP_PARAMS) {
    i0 += i1;
    CP_TAIL finish(CP_ARGS);
}
uint64_t cp_fixture_sum10(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,
                      uint64_t f,uint64_t g,uint64_t h,uint64_t i,uint64_t j) {
    return a+2*b+3*c+4*d+5*e+6*f+7*g+8*h+9*i+10*j;
}
double cp_fixture_float10(double a,double b,double c,double d,double e,double f,
                       double g,double h,double i,double j) {
    return a+2*b+3*c+4*d+5*e+6*f+7*g+8*h+9*i+10*j;
}
typedef struct Mixed { uint64_t a; double b; } Mixed;
typedef struct Large { uint64_t a,b,c; } Large;
Mixed cp_fixture_mixed(Mixed m,uint64_t n) { return (Mixed){m.a+n,m.b*2}; }
Large cp_fixture_large(uint64_t a,uint64_t b) { return (Large){a,b,a+b}; }
uint64_t cp_fixture_stack_aggregate(uint64_t a,uint64_t b,uint64_t c,uint64_t d,
                                uint64_t e,Large v,uint64_t f) {
    return a+b+c+d+e+f+v.a+2*v.b+3*v.c;
}
double cp_fixture_variadic(unsigned n,...) {
    va_list ap; va_start(ap,n); double r=0;
    for(unsigned i=0;i<n;++i) r+=va_arg(ap,double);
    va_end(ap); return r;
}
typedef struct BumpArgs { void (*entry)(void *,uint32_t); void *counter; uint32_t count; } BumpArgs;
static void *parallel_bump(void *raw) {
    BumpArgs *a=raw; a->entry(a->counter,a->count); return NULL;
}
int cp_fixture_parallel_bump(void (*entry)(void *,uint32_t),void *counter,uint32_t threads,uint32_t count) {
    pthread_t ids[8]; BumpArgs args={entry,counter,count};
    if (!threads || threads>8) return -1;
    uint32_t started=0;
    while (started<threads && !pthread_create(&ids[started],NULL,parallel_bump,&args)) ++started;
    for (uint32_t i=0;i<started;++i) if (pthread_join(ids[i],NULL)) abort();
    return started==threads ? 0 : -1;
}
typedef struct Two { uint64_t a,b; } Two;
uint64_t cp_fixture_rollback(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,Two v,uint64_t f) {
    return a+b+c+d+e+f+v.a+2*v.b;
}
double cp_fixture_call_mixed(Mixed (*fn)(Mixed,uint64_t),uint64_t a,double b,uint64_t n) {
    Mixed result=fn((Mixed){a,b},n); return (double)result.a+result.b;
}
uint64_t cp_fixture_call_large(Large (*fn)(uint64_t,uint64_t),uint64_t a,uint64_t b) {
    Large result=fn(a,b); return result.a+result.b+result.c;
}
static void put_double(cp_vec *v,double x) { *v=(cp_vec){0,0}; memcpy(v,&x,8); }
static double get_double(const cp_vec *v) { double x; memcpy(&x,v,8); return x; }
static void put_float(cp_vec *v,float x) { *v=(cp_vec){0,0}; memcpy(v,&x,4); }
static float get_float(const cp_vec *v) { float x; memcpy(&x,v,4); return x; }
static float float_result(float x) { return x+0.5f; }

static void *entry(const cp_entry_desc *desc) {
    void *p=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(p!=MAP_FAILED); cp_entry_write(p,desc);
    assert(!mprotect(p,4096,PROT_READ|PROT_EXEC)); return p;
}
static void dispatch_add(void *user,cp_call_image *image) {
    cp_bank in=bank(),out={0};
    in.i[0]=image->gpr[0]; in.i[1]=image->gpr[1];
    cp_context ctx={.result=(unsigned char *)&out,.user=user};
    cp_invoke(add_inputs,&ctx,&in);
    image->ret_gpr[0]=out.i[0]+(uintptr_t)user;
}
uint64_t cp_fixture_callback(uint64_t (*fn)(uint64_t,uint64_t),uint64_t a,uint64_t b) {
    return fn(a,b)+100;
}
static uint64_t callback(void *raw,uint64_t a,uint64_t b) {
    uint64_t (*fn)(uint64_t,uint64_t)=(uint64_t (*)(uint64_t,uint64_t))raw;
    return fn(a,b)+100;
}
static void dispatch_many(void *user,cp_call_image *im) {
    (void)user; uint64_t tail[4]; memcpy(tail,im->stack_data,sizeof tail);
    im->ret_gpr[0]=cp_fixture_sum10(im->gpr[0],im->gpr[1],im->gpr[2],im->gpr[3],im->gpr[4],
                         im->gpr[5],tail[0],tail[1],tail[2],tail[3]);
}
static void dispatch_mixed(void *user,cp_call_image *im) {
    (void)user; im->ret_gpr[0]=im->gpr[0]+im->gpr[1];
    put_double(&im->ret_xmm[0],get_double(&im->xmm[0])*2);
}
static void dispatch_large(void *user,cp_call_image *im) {
    (void)user; Large v={im->gpr[1],im->gpr[2],im->gpr[1]+im->gpr[2]};
    memcpy((void *)(uintptr_t)im->gpr[0],&v,sizeof v); im->ret_gpr[0]=im->gpr[0];
}
static void dispatch_floats(void *user,cp_call_image *im) {
    (void)user; double r=0,tail[2]; memcpy(tail,im->stack_data,sizeof tail);
    for(unsigned i=0;i<8;++i) r+=(i+1)*get_double(&im->xmm[i]);
    r+=9*tail[0]+10*tail[1]; put_double(&im->ret_xmm[0],r);
}
static void dispatch_variadic(void *user,cp_call_image *im) {
    (void)user; assert(im->vector_count==3 && im->gpr[0]==3);
    put_double(&im->ret_xmm[0],get_double(&im->xmm[0])+get_double(&im->xmm[1])+get_double(&im->xmm[2]));
}
static void preservation_driver(void *unused) {
    (void)unused; cp_bank in=bank(),out={0}; cp_context ctx={.result=(unsigned char *)&out};
    cp_invoke(cp_test_capture,&ctx,&in); assert(bank_equal(&in,&out));
    cp_call_image image={.target=(void *)cp_test_clobber}; ctx.user=&image;
    cp_invoke(native_call,&ctx,&in); in.i[0]=123456; assert(bank_equal(&in,&out));
    cp_entry_desc desc={dispatch_add,(void *)7}; void *p=entry(&desc);
    assert(((uint64_t (*)(uint64_t,uint64_t))p)(11,19)==37);
    assert(!munmap(p,4096));
}
static _Thread_local jmp_buf escape;
static uint64_t escape_native(void) { longjmp(escape,1); }
static void *thread(void *raw) {
    for(unsigned i=0;i<1000;++i) {
        cp_bank in=bank(),out={0};
        cp_call_image im={.target=(void *)callback,.gpr={(uintptr_t)raw,i,17}};
        cp_context ctx={.result=(unsigned char *)&out,.user=&im};
        cp_invoke(native_call,&ctx,&in); in.i[0]=i+17+7+100;
        assert(bank_equal(&in,&out));
    }
    return NULL;
}
int main(void) {
    cp_bank in=bank(),out={0}; cp_context ctx={.result=(unsigned char *)&out};
    cp_invoke(cp_test_capture,&ctx,&in); CHECK(bank_equal(&in,&out));
    cp_invoke(finish,&ctx,&in); CHECK(bank_equal(&in,&out));
    in.i[0]=1000000; in.i[1]=0;
    cp_invoke(loop,&ctx,&in); in.i[0]=0; in.i[1]=500000500000ULL;
    CHECK(bank_equal(&in,&out));
    CHECK(cp_test_preserved(preservation_driver,NULL)==0);

    cp_call_image im={.target=(void *)cp_fixture_sum10,.gpr={1,2,3,4,5,6}};
    uint64_t stack[]={7,8,9,10}; im.stack_data=(unsigned char *)stack; im.stack_size=sizeof stack;
    in=bank(); ctx.user=&im; cp_invoke(native_call,&ctx,&in);
    in.i[0]=385; CHECK(bank_equal(&in,&out));
    im=(cp_call_image){.target=(void *)cp_fixture_float10,.vector_count=8};
    for(unsigned i=0;i<8;++i) put_double(&im.xmm[i],i+1);
    double fs[]={9,10}; im.stack_data=(unsigned char *)fs; im.stack_size=sizeof fs;
    cp_native_call(&im); CHECK(get_double(&im.ret_xmm[0])==385);
    im=(cp_call_image){.target=(void *)float_result}; put_float(&im.xmm[0],1.25f);
    cp_native_call(&im); CHECK(get_float(&im.ret_xmm[0])==1.75f);
    im=(cp_call_image){.target=(void *)cp_fixture_mixed,.gpr={7,8}}; put_double(&im.xmm[0],1.25);
    cp_native_call(&im); CHECK(im.ret_gpr[0]==15 && get_double(&im.ret_xmm[0])==2.5);
    Large result;
    im=(cp_call_image){.target=(void *)cp_fixture_large,.gpr={(uintptr_t)&result,33,44}};
    cp_native_call(&im); CHECK(result.a==33 && result.b==44 && result.c==77 && im.ret_gpr[0]==(uintptr_t)&result);
    Large arg={7,8,9}; im=(cp_call_image){.target=(void *)cp_fixture_stack_aggregate,.gpr={1,2,3,4,5,6},
        .stack_data=(unsigned char *)&arg,.stack_size=sizeof arg};
    cp_native_call(&im); CHECK(im.ret_gpr[0]==71);
    im=(cp_call_image){.target=(void *)cp_fixture_variadic,.gpr={3},.vector_count=3};
    put_double(&im.xmm[0],1.5); put_double(&im.xmm[1],2.5); put_double(&im.xmm[2],4);
    cp_native_call(&im); CHECK(get_double(&im.ret_xmm[0])==8);
    im=(cp_call_image){.target=(void *)cp_test_stack_align}; cp_native_call(&im); CHECK(im.ret_gpr[0]==8);

    cp_entry_desc desc={dispatch_add,(void *)7}; void *p=entry(&desc);
    CHECK(((uint64_t (*)(uint64_t,uint64_t))p)(11,19)==37);
    im=(cp_call_image){.target=(void *)callback,.gpr={(uintptr_t)p,11,19}};
    in=bank(); ctx.user=&im; cp_invoke(native_call,&ctx,&in); in.i[0]=137;
    CHECK(bank_equal(&in,&out));
    pthread_t threads[4];
    for(unsigned i=0;i<4;++i) assert(!pthread_create(&threads[i],NULL,thread,p));
    for(unsigned i=0;i<4;++i) assert(!pthread_join(threads[i],NULL));
    CHECK(!munmap(p,4096));
    desc=(cp_entry_desc){dispatch_many,NULL}; p=entry(&desc);
    CHECK(((uint64_t (*)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t))p)(1,2,3,4,5,6,7,8,9,10)==385);
    CHECK(!munmap(p,4096));
    desc=(cp_entry_desc){dispatch_mixed,NULL}; p=entry(&desc);
    Mixed m=((Mixed (*)(Mixed,uint64_t))p)((Mixed){7,1.25},8);
    CHECK(m.a==15 && m.b==2.5); CHECK(!munmap(p,4096));
    desc=(cp_entry_desc){dispatch_large,NULL}; p=entry(&desc);
    result=((Large (*)(uint64_t,uint64_t))p)(33,44);
    CHECK(result.a==33 && result.b==44 && result.c==77); CHECK(!munmap(p,4096));
    desc=(cp_entry_desc){dispatch_floats,NULL}; p=entry(&desc);
    CHECK(((double (*)(double,double,double,double,double,double,double,double,double,double))p)(1,2,3,4,5,6,7,8,9,10)==385);
    CHECK(!munmap(p,4096));
    desc=(cp_entry_desc){dispatch_variadic,NULL}; p=entry(&desc);
    CHECK(((double (*)(unsigned,...))p)(3,1.5,2.5,4.0)==8); CHECK(!munmap(p,4096));
    if(!setjmp(escape)) {
        im=(cp_call_image){.target=(void *)escape_native}; ctx.user=&im;
        cp_invoke(native_call,&ctx,&in); assert(!"longjmp returned");
    }
    /* Non-volatile locals modified after setjmp are indeterminate after longjmp.
     * Establish a fresh invocation instead of accidentally relying on them. */
    cp_bank after_in=bank(),after_out={0};
    cp_context after_ctx={.result=(unsigned char *)&after_out};
    cp_invoke(finish,&after_ctx,&after_in); CHECK(bank_equal(&after_in,&after_out));
    printf("direct ABI: %u checks + 4000 concurrent nested callbacks passed\n",checks);
    return 0;
}

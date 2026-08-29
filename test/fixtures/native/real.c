/* Compiled by clang -O2 for wasm32: real optimised compiler output, exercising
   loops, recursion, memory, indirect calls and float arithmetic. */
#include <stdint.h>

__attribute__((visibility("default"))) int add(int a, int b) { return a + b; }

__attribute__((visibility("default"))) int fib(int n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

__attribute__((visibility("default"))) uint32_t sum_to(uint32_t n) {
    uint32_t s = 0;
    for (uint32_t i = 0; i < n; i++) s += i;
    return s;
}

static unsigned char buf[4096];
__attribute__((visibility("default"))) int memops(int n) {
    for (int i = 0; i < n && i < 4096; i++) buf[i] = (unsigned char)(i * 7);
    int s = 0;
    for (int i = 0; i < n && i < 4096; i++) s += buf[i];
    return s;
}

__attribute__((visibility("default"))) double fmix(double x, int n) {
    double acc = 0.0;
    for (int i = 1; i <= n; i++) acc += x / (double)i;
    return acc;
}

typedef int (*binop)(int, int);
static int mul(int a, int b) { return a * b; }
static binop table[2] = { add, mul };
__attribute__((visibility("default"))) int indirect(int which, int a, int b) {
    return table[which & 1](a, b);
}

__attribute__((visibility("default"))) int64_t i64ops(int64_t a, int64_t b) {
    return (a * b) ^ (a >> 3) ^ (b << 5);
}

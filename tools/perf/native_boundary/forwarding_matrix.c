/* Store-to-load forwarding matrix for a 16-byte JSValue slot (AArch64).
 *
 * Why: the interpreter moves JSValues between the operand stack, the frame
 * argument/local windows and `Vm.return_value` constantly, and LLVM is free to
 * lower every 16-byte copy either as one `ldr q` / `str q` pair or as two
 * 64-bit general-register accesses.  Several handlers pin the general-register
 * form with inline asm; this program is the measurement those comments cite.
 *
 * Method: a dependency chain of (store, load, close) triples -- the value the
 * load produces feeds the data of the next store -- so the reported number is
 * the store->load->store latency, not throughput.  The `CTRL` rows load a slot
 * nothing in the loop wrote (no forwarding), which is the floor.  Compare rows
 * only WITHIN one consumer group: the chain-closing instruction differs
 * between a general-register consumer (`mov`) and a SIMD one (`fmov`).
 *
 *   gcc -O2 -o /tmp/fwd tools/perf/native_boundary/forwarding_matrix.c
 *   taskset -c 19 /tmp/fwd        # measurement CPU, machine otherwise idle
 *
 * The absolute numbers move with machine load (a busy host scaled every row
 * by ~1.6x); the ratios between rows of one consumer group are what matters.
 *
 * Reading on this host (Cortex-X925, 2026-09-07, cycles at 3.4 GHz):
 *
 *   producer               `ldr x`   `ldp x,x`   `ldr q`
 *   str x                     6.9        7.1       11.3
 *   stp x,x                   6.9        7.0       11.1
 *   str x; str x              7.1        7.4       11.3
 *   str q                    10.9       10.9       15.6
 *   str d                    10.8         -          -
 *   str q, upper half        14.0          (`ldr x` at +8)
 *
 * Conclusion: the penalty is the register DOMAIN, not the access width.  A
 * general-register load forwards equally well from a `stp` pair, from two
 * separate `str`s, and from a partially overlapping older store; it never
 * forwards from a SIMD store (+4 cyc, +7 for the upper half).  A `ldr q` is
 * ~4 cyc worse than a general-register load whoever wrote the bytes, and
 * `str q -> ldr q` -- what LLVM emits for an unpinned slot-to-slot copy read
 * back by the next handler -- is the worst cell in the table.  So the rule for
 * a JSValue in an operand-stack or frame slot is: no `q`/`d` register ever
 * touches one.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

static uint64_t buf[64] __attribute__((aligned(64)));

#define R8(x) x x x x x x x x

#define MK(name, PRE, STORE, LOAD, CLOSE)                                \
static double name(uint64_t n) {                                         \
    struct timespec a, b; uint64_t m = n;                                \
    clock_gettime(CLOCK_MONOTONIC, &a);                                  \
    __asm__ __volatile__(                                                \
        "mov x9, #0\n" "mov x10, #0\n" "mov x11, #0\n"                   \
        "movi v0.2d, #0\n" "movi v1.2d, #0\n" "mov x1, %[base]\n"        \
        "1:\n" R8(PRE "\n" STORE "\n" LOAD "\n" CLOSE "\n")              \
        "subs %[n], %[n], #1\n" "b.ne 1b\n"                              \
        : [n] "+r" (m) : [base] "r" (buf)                                \
        : "x1","x9","x10","x11","x12","v0","v1","memory","cc");          \
    clock_gettime(CLOCK_MONOTONIC, &b);                                  \
    double ns = (b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec);   \
    return ns / (double)(n * 8);                                         \
}

/* consumer: ldr x (64-bit general register), payload half */
MK(A0, "", "nop",                                  "ldr x9, [x1]",      "mov x10, x9")
MK(A1, "", "str x10, [x1]",                        "ldr x9, [x1]",      "mov x10, x9")
MK(A2, "", "stp x10, x11, [x1]",                   "ldr x9, [x1]",      "mov x10, x9")
MK(A3, "", "str x10, [x1]\n str x11, [x1, #8]",    "ldr x9, [x1]",      "mov x10, x9")
MK(A4, "fmov d0, x10", "str q0, [x1]",             "ldr x9, [x1]",      "mov x10, x9")
MK(A5, "fmov d0, x10", "str d0, [x1]",             "ldr x9, [x1]",      "mov x10, x9")
/* consumer: ldr x, tag half (+8) */
MK(B1, "", "str x10, [x1, #8]",                    "ldr x9, [x1, #8]",  "mov x10, x9")
MK(B2, "", "stp x11, x10, [x1]",                   "ldr x9, [x1, #8]",  "mov x10, x9")
MK(B4, "fmov d0, x10\n mov v0.d[1], x10", "str q0, [x1]", "ldr x9, [x1, #8]", "mov x10, x9")
/* consumer: ldp x,x (one 16-byte general-register access) */
MK(C0, "", "nop",                                  "ldp x9, x12, [x1]", "mov x10, x9")
MK(C1, "", "stp x10, x11, [x1]",                   "ldp x9, x12, [x1]", "mov x10, x9")
MK(C2, "", "str x10, [x1]\n str x11, [x1, #8]",    "ldp x9, x12, [x1]", "mov x10, x9")
MK(C3, "fmov d0, x10", "str q0, [x1]",             "ldp x9, x12, [x1]", "mov x10, x9")
/* only the low half is rewritten in the loop; the high half is an old store */
MK(C4, "", "str x10, [x1]",                        "ldp x9, x12, [x1]", "mov x10, x9")
/* consumer: ldr q (16-byte SIMD access) */
MK(D0, "", "nop",                                  "ldr q1, [x1]",      "fmov x10, d1")
MK(D1, "fmov d0, x10", "str q0, [x1]",             "ldr q1, [x1]",      "fmov x10, d1")
MK(D2, "", "stp x10, x11, [x1]",                   "ldr q1, [x1]",      "fmov x10, d1")
MK(D3, "", "str x10, [x1]\n str x11, [x1, #8]",    "ldr q1, [x1]",      "fmov x10, d1")

int main(int argc, char **argv) {
    double ghz = argc > 1 ? atof(argv[1]) : 3.4;
    uint64_t n = 3000000;
    struct { const char *s; double (*f)(uint64_t); } t[] = {
        {"CTRL  (no store) -> ldr x   ", A0},
        {"str x            -> ldr x   ", A1},
        {"stp x,x          -> ldr x   ", A2},
        {"str x; str x     -> ldr x   ", A3},
        {"str q            -> ldr x   ", A4},
        {"str d            -> ldr x   ", A5},
        {"str x @8         -> ldr x @8", B1},
        {"stp x,x          -> ldr x @8", B2},
        {"str q            -> ldr x @8", B4},
        {"CTRL  (no store) -> ldp x,x ", C0},
        {"stp x,x          -> ldp x,x ", C1},
        {"str x; str x     -> ldp x,x ", C2},
        {"str q            -> ldp x,x ", C3},
        {"str x (hi older) -> ldp x,x ", C4},
        {"CTRL  (no store) -> ldr q   ", D0},
        {"str q            -> ldr q   ", D1},
        {"stp x,x          -> ldr q   ", D2},
        {"str x; str x     -> ldr q   ", D3},
    };
    for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++) t[i].f(100000);
    for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
        double best = 1e18;
        for (int r = 0; r < 5; r++) { double v = t[i].f(n); if (v < best) best = v; }
        printf("%s  %6.2f ns  (%5.2f cyc)\n", t[i].s, best, best * ghz);
    }
    return 0;
}

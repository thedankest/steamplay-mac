/* tsoprobe: checks that x86 memory ordering (TSO) holds for this process, and times a compute
 * loop. Runner B's B1 gate (research/RUNNER-B-PLAN.md): under FEX on Apple Silicon, x86 code is
 * only correct if FEX switched the thread to hardware TSO (thread_set_x86_64_compat, traced by
 * FEXUNIX_TRACE=1 as "TSOControl 1 kr=0") or emits barriers itself.
 *
 * Litmus test "MP" (message passing), run for N iterations:
 *   writer: for i = 1..N { data = i; flag = i; }        (two plain stores, in program order)
 *   reader: loop { f = flag; d = data; if (d < f) violation; } until f == N
 * x86 never reorders store-store or load-load, so a reader that sees flag == i must see
 * data >= i. On a weakly ordered ARM core without TSO either reordering can show up.
 * "overlap" counts reads that saw the writer mid-run (0 < f < N): if it is tiny, the two threads
 * did not really run concurrently and a zero violation count means little.
 *
 * Build (tests/Makefile): x86_64-w64-mingw32-gcc / i686-w64-mingw32-gcc -O2 -o tsoprobe.exe tsoprobe.c
 * Usage: tsoprobe [--iters N] [--compute M] [--no-litmus] [--no-compute]
 * Exit code: 0 no violations, 1 violations seen, 2 usage or thread error. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CACHELINE 128   /* Apple cores use 128-byte lines */

/* data and flag on separate cache lines, so their updates travel independently */
static struct {
    volatile LONG data;
    char pad1[CACHELINE - sizeof(LONG)];
    volatile LONG flag;
    char pad2[CACHELINE - sizeof(LONG)];
    volatile LONG start;
} shared __attribute__((aligned(CACHELINE)));

static LONG iters = 10000000;

#define compiler_barrier() __asm__ __volatile__("" ::: "memory")

static DWORD WINAPI writer(void *arg)
{
    LONG i;
    (void)arg;
    while (!shared.start) compiler_barrier();
    for (i = 1; i <= iters; i++)
    {
        shared.data = i;   /* volatile: emitted in this order, as plain movs */
        shared.flag = i;
    }
    return 0;
}

struct reader_result { unsigned long long reads, violations, overlap; LONG first_bad_f, first_bad_d; };

static DWORD WINAPI reader(void *arg)
{
    struct reader_result *r = arg;
    LONG f, d;
    while (!shared.start) compiler_barrier();
    do
    {
        f = shared.flag;
        d = shared.data;
        r->reads++;
        if (f > 0 && f < iters) r->overlap++;
        if (d < f)
        {
            if (!r->violations) { r->first_bad_f = f; r->first_bad_d = d; }
            r->violations++;
        }
    } while (f != iters);
    return 0;
}

static double now_ms(void)
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}

static void report_machine(void)
{
    typedef BOOL (WINAPI *IsWow64Process2_t)(HANDLE, USHORT *, USHORT *);
    IsWow64Process2_t p = (IsWow64Process2_t)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process2");
    USHORT process = 0, native = 0;
    printf("tsoprobe: built for %s, pointer size %u\n",
#if defined(__x86_64__)
           "x86_64",
#elif defined(__i386__)
           "i386",
#elif defined(__aarch64__)
           "aarch64",
#else
           "unknown",
#endif
           (unsigned)sizeof(void *));
    /* Runner B: native 0xaa64 (process 0x14c for i386 under WoW64). Runner A: native 0x8664. */
    if (p && p(GetCurrentProcess(), &process, &native))
        printf("  IsWow64Process2: process machine %#x, native machine %#x\n", process, native);
    else
        printf("  IsWow64Process2: not available\n");
}

static int litmus(void)
{
    struct reader_result r = {0};
    HANDLE th[2];
    double t0, t1;

    shared.data = shared.flag = shared.start = 0;
    th[0] = CreateThread(NULL, 0, writer, NULL, 0, NULL);
    th[1] = CreateThread(NULL, 0, reader, &r, 0, NULL);
    if (!th[0] || !th[1]) { printf("litmus mp: CreateThread failed (%lu)\n", GetLastError()); return 2; }
    Sleep(10);   /* let both threads reach the start line */
    t0 = now_ms();
    shared.start = 1;
    WaitForMultipleObjects(2, th, TRUE, INFINITE);
    t1 = now_ms();
    CloseHandle(th[0]);
    CloseHandle(th[1]);

    printf("litmus mp: iters=%ld reads=%llu overlap=%llu violations=%llu ms=%.1f\n", (long)iters,
           r.reads, r.overlap, r.violations, t1 - t0);
    if (r.violations)
        printf("  first violation: saw flag=%ld but data=%ld (x86 ordering broken: TSO is off)\n",
               (long)r.first_bad_f, (long)r.first_bad_d);
    if (r.overlap < 1000)
        printf("  note: little overlap between writer and reader; the result is weak evidence\n");
    return r.violations ? 1 : 0;
}

/* Integer and floating-point work with a checksum, so nothing is optimised away. Compare ms
 * between runners (gate: Runner B within 20% of Runner A). */
static void compute(unsigned long long m)
{
    unsigned long long x = 0x9e3779b97f4a7c15ull, sum = 0, i;
    double acc = 0.0;
    double t0 = now_ms(), t1;
    for (i = 0; i < m; i++)
    {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;   /* xorshift64 */
        sum += (x >> 32) * (unsigned)(i | 1);
        acc += (double)(x & 0xffff) * 1e-4;
        if ((i & 0xfff) == 0) acc *= 0.5;
    }
    t1 = now_ms();
    printf("compute: iters=%llu checksum=%016llx acc=%.3f ms=%.1f\n", m, sum ^ x, acc, t1 - t0);
}

int main(int argc, char **argv)
{
    unsigned long long compute_iters = 400000000ull;
    int do_litmus = 1, do_compute = 1, i, ret = 0;

    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters = atol(argv[++i]);
        else if (!strcmp(argv[i], "--compute") && i + 1 < argc) compute_iters = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--no-litmus")) do_litmus = 0;
        else if (!strcmp(argv[i], "--no-compute")) do_compute = 0;
        else { fprintf(stderr, "usage: tsoprobe [--iters N] [--compute M] [--no-litmus] [--no-compute]\n"); return 2; }
    }
    if (iters < 1) { fprintf(stderr, "tsoprobe: --iters must be at least 1\n"); return 2; }

    report_machine();
    if (do_litmus) ret = litmus();
    if (do_compute) compute(compute_iters);
    fflush(stdout);
    return ret;
}

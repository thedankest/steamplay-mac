/* syscallprobe: a counted loop of QueryPerformanceCounter calls, each one an NtQueryPerformanceCounter
 * syscall through the emulator (WoW64 or ARM64EC thunk). Built for i386 and x86_64.
 *
 * Why: on Runner B with the Hangover 11.16 FEX DLLs every 32-bit game crashed after about 65.8K
 * WoW64 syscalls with an access violation just below a 4 MB + 8 KB FEX reservation (Alien Breed 3,
 * fault 0x123AAFFF0 in the i386 ntdll NtQueryPerformanceCounter thunk). The suspected cause is
 * FEX 2608's 4 KB call/return-stack guard page, which on macOS shares a 16 KB host page with
 * committed memory and so never faults (Wine ORs the four 4 KB protections). FEX-darwin keeps
 * each guard on its own 16 KB page (research/FEX-DARWIN.md §2). Pass the number of calls
 * (default 300000, well past 65.8K); progress is printed every 10000 calls so the crash point
 * is visible. Exit 0 when every call returned. */
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

int main(int argc, char **argv)
{
    LARGE_INTEGER li, f;
    unsigned long i, n = argc > 1 ? strtoul(argv[1], NULL, 0) : 300000;

    QueryPerformanceFrequency(&f);
    printf("syscallprobe: %lu QueryPerformanceCounter calls, pointer size %d, qpc freq %lld\n",
           n, (int)sizeof(void *), (long long)f.QuadPart);
    fflush(stdout);
    for (i = 1; i <= n; i++)
    {
        if (!QueryPerformanceCounter(&li)) { printf("call %lu failed\n", i); return 2; }
        if (i % 10000 == 0) { printf("  %lu calls ok (qpc %lld)\n", i, (long long)li.QuadPart); fflush(stdout); }
    }
    printf("done: %lu calls\n", n);
    return 0;
}

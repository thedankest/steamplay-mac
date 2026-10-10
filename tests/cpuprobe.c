/* cpuprobe: what an x86 guest sees of the host CPU through the emulator: CPUID leaf 1/7 feature bits
 * and IsProcessorFeaturePresent for SSE4.2/AVX/AVX2. Built for x86_64 and i386. First written in the
 * Steam integration thread (2026-10-10 03:05, Runner B hid SSE4.2); used by tests/try-fex-darwin.sh to
 * check that FEX derives SSE4.2 (from CRC32) and AES/PCLMULQDQ (from the crypto extensions) from the
 * CP xxxx ID-register values Wine publishes (patches/runner-b/0025), without FEX_HOSTFEATURES. */
#include <stdio.h>
#include <windows.h>
#include <intrin.h>
int main(void)
{
    int r[4];
    __cpuid(r, 0); printf("max leaf %d\n", r[0]);
    __cpuid(r, 1);
    printf("leaf1 ecx=%08x sse3=%d ssse3=%d sse4.1=%d sse4.2=%d popcnt=%d avx=%d osxsave=%d\n", r[2],
           r[2]&1, (r[2]>>9)&1, (r[2]>>19)&1, (r[2]>>20)&1, (r[2]>>23)&1, (r[2]>>28)&1, (r[2]>>27)&1);
    __cpuidex(r, 7, 0); printf("leaf7 ebx=%08x avx2=%d bmi1=%d bmi2=%d\n", r[1], (r[1]>>5)&1, (r[1]>>3)&1, (r[1]>>8)&1);
    printf("PF sse3(13)=%d ssse3(36)=%d sse4.1(37)=%d sse4.2(38)=%d avx(39)=%d avx2(40)=%d\n",
        IsProcessorFeaturePresent(13), IsProcessorFeaturePresent(36), IsProcessorFeaturePresent(37),
        IsProcessorFeaturePresent(38), IsProcessorFeaturePresent(39), IsProcessorFeaturePresent(40));
    return 0;
}

# Windows test programs, built with Homebrew's mingw-w64 (the toolchain d3dprobe always used).
#   make -C tests                 d3dprobe.exe d3dprobe32.exe tsoprobe.exe tsoprobe32.exe
#                                 steamprobe.exe steamprobe32.exe syscallprobe.exe syscallprobe32.exe
#                                 cpuprobe.exe cpuprobe32.exe
#   make -C tests aarch64         d3dprobe-arm64.exe tsoprobe-arm64.exe (needs llvm-mingw:
#                                 LLVM_MINGW=build/wine-arm64/toolchains/llvm-mingw)
#   make -C tests O=/some/dir     put the .exe files elsewhere (default: tests/, git-ignored)
O ?= .
CC64 ?= x86_64-w64-mingw32-gcc
CC32 ?= i686-w64-mingw32-gcc
LLVM_MINGW ?= ../build/wine-arm64/toolchains/llvm-mingw
CCA64 ?= $(LLVM_MINGW)/bin/aarch64-w64-mingw32-clang
CFLAGS ?= -O2 -Wall
D3DLIBS = -ld3d11 -ldxgi -ld3d12 -lole32 -luuid -luser32

PROBES = $(O)/d3dprobe.exe $(O)/d3dprobe32.exe $(O)/tsoprobe.exe $(O)/tsoprobe32.exe \
         $(O)/steamprobe.exe $(O)/steamprobe32.exe $(O)/syscallprobe.exe $(O)/syscallprobe32.exe \
         $(O)/cpuprobe.exe $(O)/cpuprobe32.exe

all: $(PROBES)
aarch64: $(O)/d3dprobe-arm64.exe $(O)/tsoprobe-arm64.exe

$(O)/d3dprobe.exe: d3dprobe.c
	$(CC64) $(CFLAGS) -o $@ $< $(D3DLIBS)
$(O)/d3dprobe32.exe: d3dprobe.c
	$(CC32) $(CFLAGS) -o $@ $< $(D3DLIBS)
$(O)/d3dprobe-arm64.exe: d3dprobe.c
	$(CCA64) $(CFLAGS) -o $@ $< $(D3DLIBS)

$(O)/tsoprobe.exe: tsoprobe.c
	$(CC64) $(CFLAGS) -o $@ $<
$(O)/tsoprobe32.exe: tsoprobe.c
	$(CC32) $(CFLAGS) -o $@ $<
$(O)/tsoprobe-arm64.exe: tsoprobe.c
	$(CCA64) $(CFLAGS) -o $@ $<

$(O)/steamprobe.exe: steamprobe.c
	$(CC64) $(CFLAGS) -o $@ $<
$(O)/steamprobe32.exe: steamprobe.c
	$(CC32) $(CFLAGS) -o $@ $<

$(O)/syscallprobe.exe: syscallprobe.c
	$(CC64) $(CFLAGS) -o $@ $<
$(O)/syscallprobe32.exe: syscallprobe.c
	$(CC32) $(CFLAGS) -o $@ $<

$(O)/cpuprobe.exe: cpuprobe.c
	$(CC64) $(CFLAGS) -o $@ $<
$(O)/cpuprobe32.exe: cpuprobe.c
	$(CC32) $(CFLAGS) -o $@ $<

clean:
	rm -f $(PROBES) $(O)/d3dprobe-arm64.exe $(O)/tsoprobe-arm64.exe

.PHONY: all aarch64 clean

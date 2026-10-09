/* d3dprobe: creates a Direct3D 11 and a Direct3D 12 device and reports what answered.
 * With --present N it instead opens a window with a D3D11/DXGI swapchain, presents N frames of
 * cycling clear colours and reports the last HRESULT (Runner B's B2 gate: --present 300 -> S_OK).
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -ld3d12 -lole32 -luuid
 *        (or tests/Makefile, which also builds the i386 and aarch64 variants)
 * Usage: d3dprobe [11|12]        d3dprobe --present N
 * Exit code: 0 when every requested API produced a device, or every frame presented. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static void module_path(const char *name)
{
    char path[MAX_PATH] = "";
    HMODULE m = GetModuleHandleA(name);
    if (m) GetModuleFileNameA(m, path, sizeof(path));
    printf("  %-12s %s\n", name, m ? path : "(not loaded)");
}

static int probe_d3d11(void)
{
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &dev, &fl, &ctx);
    printf("d3d11: hr=%#lx feature_level=%#x\n", (unsigned long)hr, (unsigned)fl);
    if (FAILED(hr)) return 1;
    IDXGIDevice *dxgi_dev;
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev)))
    {
        IDXGIAdapter *ad;
        DXGI_ADAPTER_DESC desc;
        if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_dev, &ad)) && SUCCEEDED(IDXGIAdapter_GetDesc(ad, &desc)))
            printf("  adapter: %ls vendor=%04x device=%04x vram=%llu MB\n", desc.Description,
                   desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory >> 20);
        IDXGIDevice_Release(dxgi_dev);
    }
    module_path("d3d11.dll");
    module_path("dxgi.dll");
    module_path("winemetal.dll");
    ID3D11DeviceContext_Release(ctx);
    ID3D11Device_Release(dev);
    return 0;
}

static int probe_d3d12(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    printf("d3d12: hr=%#lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5))))
        printf("  raytracing tier=%d\n", o5.RaytracingTier);
    module_path("d3d12.dll");
    module_path("dxgi.dll");
    ID3D12Device_Release(dev);
    return 0;
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_CLOSE) { DestroyWindow(hwnd); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static int create_swapchain(HWND hwnd, DXGI_SWAP_EFFECT effect, UINT buffers, IDXGISwapChain **sc,
                            ID3D11Device **dev, ID3D11DeviceContext **ctx, D3D_FEATURE_LEVEL *fl, HRESULT *hr)
{
    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferDesc.Width = 640;
    desc.BufferDesc.Height = 480;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = buffers;
    desc.OutputWindow = hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = effect;
    *hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                        &desc, sc, dev, fl, ctx);
    return SUCCEEDED(*hr);
}

static int present_frames(int frames)
{
    WNDCLASSA wc = {0};
    HWND hwnd;
    IDXGISwapChain *sc = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    const char *model = "flip_discard";
    HRESULT hr, last = S_OK;
    DWORD t0;
    MSG msg;
    int i, shown = 0;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "d3dprobe";
    RegisterClassA(&wc);
    hwnd = CreateWindowA("d3dprobe", "d3dprobe --present", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         CW_USEDEFAULT, CW_USEDEFAULT, 640, 480, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("present: CreateWindow failed (%lu)\n", GetLastError()); return 1; }

    /* the flip model first (what current games use), then the legacy blit model */
    if (!create_swapchain(hwnd, DXGI_SWAP_EFFECT_FLIP_DISCARD, 2, &sc, &dev, &ctx, &fl, &hr))
    {
        printf("present: flip_discard swapchain hr=%#lx, trying discard\n", (unsigned long)hr);
        model = "discard";
        if (!create_swapchain(hwnd, DXGI_SWAP_EFFECT_DISCARD, 1, &sc, &dev, &ctx, &fl, &hr))
        {
            printf("present: frames=0/%d hr=%#lx (D3D11CreateDeviceAndSwapChain)\n", frames, (unsigned long)hr);
            DestroyWindow(hwnd);
            return 1;
        }
    }
    printf("present: swapchain %s, feature_level=%#x\n", model, (unsigned)fl);
    module_path("d3d11.dll");
    module_path("dxgi.dll");
    module_path("winemetal.dll");

    hr = IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);
    if (FAILED(hr)) { printf("present: frames=0/%d hr=%#lx (render target)\n", frames, (unsigned long)hr); last = hr; goto done; }

    t0 = GetTickCount();
    for (i = 0; i < frames; i++)
    {
        float t = (float)(i % 120) / 120.0f;   /* red -> green -> blue, one cycle per 120 frames */
        float color[4] = { t < 1/3.0f ? 1 - 3 * t : t < 2/3.0f ? 0 : 3 * t - 2,
                           t < 1/3.0f ? 3 * t : t < 2/3.0f ? 2 - 3 * t : 0,
                           t < 1/3.0f ? 0 : t < 2/3.0f ? 3 * t - 1 : 3 - 3 * t, 1.0f };
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        if (!IsWindow(hwnd)) { printf("present: window closed at frame %d\n", i); break; }
        /* flip-model buffers are unbound after Present; bind every frame */
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, color);
        last = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(last)) { printf("present: Present failed at frame %d hr=%#lx\n", i, (unsigned long)last); break; }
        shown++;
    }
    printf("present: frames=%d/%d hr=%#lx ms=%lu\n", shown, frames, (unsigned long)last,
           (unsigned long)(GetTickCount() - t0));

done:
    if (rtv) ID3D11RenderTargetView_Release(rtv);
    if (back) ID3D11Texture2D_Release(back);
    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (sc) IDXGISwapChain_Release(sc);
    if (dev) ID3D11Device_Release(dev);
    if (IsWindow(hwnd)) DestroyWindow(hwnd);
    return (SUCCEEDED(last) && shown == frames) ? 0 : 1;
}

int main(int argc, char **argv)
{
    int want11 = 1, want12 = 1, fail = 0;
    if (argc > 1 && !strcmp(argv[1], "--present"))
    {
        int frames = argc > 2 ? atoi(argv[2]) : 300;
        if (frames < 1) { fprintf(stderr, "usage: d3dprobe --present N (N >= 1)\n"); return 2; }
        fail = present_frames(frames);
        fflush(stdout);
        return fail;
    }
    if (argc > 1) { want11 = !strcmp(argv[1], "11"); want12 = !strcmp(argv[1], "12"); }
    if (want11) fail |= probe_d3d11();
    if (want12) fail |= probe_d3d12();
    fflush(stdout);
    return fail;
}

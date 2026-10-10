/* d3dprobe: creates a Direct3D 11 and a Direct3D 12 device and reports what answered.
 * With --present N it instead opens a window with a D3D11/DXGI swapchain, presents N frames of
 * cycling clear colours and reports the last HRESULT (Runner B's B2 gate: --present 300 -> S_OK).
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3dprobe.exe d3dprobe.c -ld3d11 -ldxgi -ld3d12 -lole32 -luuid
 *        (or tests/Makefile, which also builds the i386 and aarch64 variants)
 * With --present12 N the same on a D3D12 device, command queue and flip-model swapchain.
 * Usage: d3dprobe [11|12]        d3dprobe --present N        d3dprobe --present12 N
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
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_12_2, D3D_FEATURE_LEVEL_12_1,
        D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fls = { ARRAYSIZE(levels), levels, 0 };
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_FEATURE_LEVELS, &fls, sizeof(fls))))
        printf("  max feature_level=%#x\n", (unsigned)fls.MaxSupportedFeatureLevel);
    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o))))
        printf("  resource binding tier=%d tiled resources tier=%d\n", o.ResourceBindingTier, o.TiledResourcesTier);
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { D3D_SHADER_MODEL_6_6 };
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm))))
        printf("  shader model=%#x\n", (unsigned)sm.HighestShaderModel);
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

/* --present12 N: the same clear-colour loop on a D3D12 device, command queue and flip-model swapchain
 * (Runner B DX12: vkd3d-proton -> winevulkan -> KosmicKrisp). One frame in flight, fence wait per frame. */
static int present_frames12(int frames)
{
    WNDCLASSA wc = {0};
    HWND hwnd;
    ID3D12Device *dev = NULL;
    ID3D12CommandQueue *queue = NULL;
    IDXGIFactory4 *factory = NULL;
    IDXGISwapChain1 *sc1 = NULL;
    IDXGISwapChain3 *sc = NULL;
    ID3D12DescriptorHeap *heap = NULL;
    ID3D12Resource *back[2] = {0};
    ID3D12CommandAllocator *alloc = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12Fence *fence = NULL;
    HANDLE event = CreateEventA(NULL, FALSE, FALSE, NULL);
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 2 };
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[2];
    UINT inc, b;
    UINT64 value = 0;
    HRESULT hr, last = S_OK;
    DWORD t0;
    MSG msg;
    int i, shown = 0;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "d3dprobe12";
    RegisterClassA(&wc);
    hwnd = CreateWindowA("d3dprobe12", "d3dprobe --present12", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                         CW_USEDEFAULT, CW_USEDEFAULT, 640, 480, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("present12: CreateWindow failed (%lu)\n", GetLastError()); return 1; }

#define CHECK(what, call) do { hr = (call); if (FAILED(hr)) { \
        printf("present12: frames=0/%d hr=%#lx (%s)\n", frames, (unsigned long)hr, what); last = hr; goto done; } } while (0)
    CHECK("D3D12CreateDevice", D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev));
    CHECK("CreateCommandQueue", ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue));
    CHECK("CreateDXGIFactory2", CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&factory));
    sd.Width = 640;
    sd.Height = 480;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    CHECK("CreateSwapChainForHwnd", IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &sc1));
    CHECK("IDXGISwapChain3", IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void **)&sc));
    CHECK("CreateDescriptorHeap", ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap));
    inc = ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(heap, &rtv[0]);   /* aggregate return, explicit form */
    rtv[1].ptr = rtv[0].ptr + inc;
    for (b = 0; b < 2; b++)
    {
        CHECK("GetBuffer", IDXGISwapChain3_GetBuffer(sc, b, &IID_ID3D12Resource, (void **)&back[b]));
        ID3D12Device_CreateRenderTargetView(dev, back[b], NULL, rtv[b]);
    }
    CHECK("CreateCommandAllocator", ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
          &IID_ID3D12CommandAllocator, (void **)&alloc));
    CHECK("CreateCommandList", ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL,
          &IID_ID3D12GraphicsCommandList, (void **)&list));
    ID3D12GraphicsCommandList_Close(list);
    CHECK("CreateFence", ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
#undef CHECK
    printf("present12: swapchain flip_discard\n");
    module_path("d3d12.dll");
    module_path("d3d12core.dll");
    module_path("dxgi.dll");
    module_path("winevulkan.dll");

    t0 = GetTickCount();
    for (i = 0; i < frames; i++)
    {
        float t = (float)(i % 120) / 120.0f;
        float color[4] = { t < 1/3.0f ? 1 - 3 * t : t < 2/3.0f ? 0 : 3 * t - 2,
                           t < 1/3.0f ? 3 * t : t < 2/3.0f ? 2 - 3 * t : 0,
                           t < 1/3.0f ? 0 : t < 2/3.0f ? 3 * t - 1 : 3 - 3 * t, 1.0f };
        D3D12_RESOURCE_BARRIER bar = {0};
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        if (!IsWindow(hwnd)) { printf("present12: window closed at frame %d\n", i); break; }
        b = IDXGISwapChain3_GetCurrentBackBufferIndex(sc);
        ID3D12CommandAllocator_Reset(alloc);
        ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
        bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        bar.Transition.pResource = back[b];
        bar.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        bar.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        bar.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &bar);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[b], color, 0, NULL);
        bar.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        bar.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &bar);
        ID3D12GraphicsCommandList_Close(list);
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
        last = IDXGISwapChain3_Present(sc, 1, 0);
        if (FAILED(last)) { printf("present12: Present failed at frame %d hr=%#lx\n", i, (unsigned long)last); break; }
        ID3D12CommandQueue_Signal(queue, fence, ++value);
        if (ID3D12Fence_GetCompletedValue(fence) < value)
        {
            ID3D12Fence_SetEventOnCompletion(fence, value, event);
            if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0)
            { printf("present12: fence timeout at frame %d\n", i); last = E_FAIL; break; }
        }
        shown++;
    }
    printf("present12: frames=%d/%d hr=%#lx ms=%lu\n", shown, frames, (unsigned long)last,
           (unsigned long)(GetTickCount() - t0));

done:
    if (fence) ID3D12Fence_Release(fence);
    if (list) ID3D12GraphicsCommandList_Release(list);
    if (alloc) ID3D12CommandAllocator_Release(alloc);
    for (b = 0; b < 2; b++) if (back[b]) ID3D12Resource_Release(back[b]);
    if (heap) ID3D12DescriptorHeap_Release(heap);
    if (sc) IDXGISwapChain3_Release(sc);
    if (sc1) IDXGISwapChain1_Release(sc1);
    if (factory) IDXGIFactory4_Release(factory);
    if (queue) ID3D12CommandQueue_Release(queue);
    if (dev) ID3D12Device_Release(dev);
    if (IsWindow(hwnd)) DestroyWindow(hwnd);
    CloseHandle(event);
    return (SUCCEEDED(last) && shown == frames) ? 0 : 1;
}

int main(int argc, char **argv)
{
    int want11 = 1, want12 = 1, fail = 0;
    if (argc > 1 && !strcmp(argv[1], "--present12"))
    {
        int frames = argc > 2 ? atoi(argv[2]) : 300;
        if (frames < 1) { fprintf(stderr, "usage: d3dprobe --present12 N (N >= 1)\n"); return 2; }
        fail = present_frames12(frames);
        fflush(stdout);
        return fail;
    }
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

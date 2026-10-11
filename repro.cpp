// Repro: ID3D11VideoContext::VideoProcessorBlt with NVIDIA's RTX Video stream extensions (VSR, TrueHDR).
//
// check mode (default): blits a known non-black NV12/P010 pattern and reads the result back, so a driver that
// returns an all-zero frame while reporting S_OK is detected. Prints HASH and RESULT, exit code 0 = content, 2 = all zero.
// stream mode: what a browser's video path does every frame (decoder-style input array, flip-model swap chain,
// extensions re-sent each frame, paced). It reads nothing back and exits 0; it prints "stream t=.. frame=.. vram_mb=.."
// once per second, the process's own video-memory use from DXGI, so growth per second and per frame can be computed.
//
// Options: see printUsage() below. The output formats and the colour space each one defaults to are the table
// kOutFormats; the other defaults are in struct Options.
//   N for a colour space is a DXGI_COLOR_SPACE_TYPE number; g22 and pq pick BT.709 gamma 2.2 / BT.2020 PQ in the
//   family of the format. Input default colour space: nv12 8, p010 13.
//   Stream mode sleeps kStreamFrameMs before each frame (so the real rate is lower; t and frame are printed) and stops after
//   --max-seconds (default 20) or when this process uses a third of the GPU memory budget, at most kCapMaxMb MB, so a
//   leaking driver cannot fill the GPU. --wait-ms delays start-up.
// Exit codes: 0 content / ok, 1 usage, 2 output is all zero, 3 API error.
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")
#pragma comment(lib, "user32.lib")
using Microsoft::WRL::ComPtr;

// NVIDIA video-processor stream extensions, as used by Chromium.
static const GUID kNvPPE = {0xd43ce1b3, 0x1f4b, 0x48ac, {0xba, 0xee, 0xc3, 0xc2, 0x53, 0x75, 0xe6, 0xf7}};   // VSR
struct NvExt { UINT version; UINT method; UINT enable; };
static const GUID kNvTrueHDR = {0xfdd62bb4, 0x620b, 0x4fd7, {0x9a, 0xb3, 0x1e, 0x59, 0xd0, 0xd5, 0x44, 0xb3}};
struct NvHdrExt { UINT version; UINT method; UINT enable : 1; UINT reserved : 31; };

#define CHK(x) do { HRESULT _h = (x); if (FAILED(_h)) { printf("FAIL %s -> 0x%08lx\n", #x, (unsigned long)_h); return 3; } } while (0)

enum class Mode { Check, Stream };

struct OutFormat { const char* name; DXGI_FORMAT fmt; DXGI_COLOR_SPACE_TYPE cs; bool yuv; UINT bps; };   // bps: bytes per sample, YUV only

struct Options {
    bool vsr = false, hdr = false;
    const OutFormat* out = nullptr;
    DXGI_COLOR_SPACE_TYPE outCS = {}, inCS = DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709;   // outCS starts as out->cs
    bool p010 = false;
    int frames = 30;
    UINT inW = 1280, inH = 720, outW = 0, outH = 0;   // out size 0 = default for the output format
    Mode mode = Mode::Check;
    ULONGLONG maxSeconds = 20;
    DWORD waitMs = 0;
};

static const UINT kExtensionVersion = 1, kVsrMethod = 2, kTrueHdrMethod = 3;   // values Chromium uses
static const UINT kTrueHdrVersion = 4;                                           // the TrueHDR struct is version 4
static const UINT kDefaultOutW = 3840, kDefaultOutH = 2160;                      // RGB output; YUV output defaults to the input size
static const DWORD kStreamFrameMs = 16;
static const UINT kDecoderArraySize = 14;                                        // stream mode's decoder-style input array

// The output formats --out accepts, with the colour space each one defaults to.
static const OutFormat kOutFormats[] = {
    { "rgb10a2", DXGI_FORMAT_R10G10B10A2_UNORM,  DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020,     false, 0 },
    { "nv12",    DXGI_FORMAT_NV12,               DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709,    true,  1 },
    { "p010",    DXGI_FORMAT_P010,               DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020, true,  2 },
};

static bool parseSize(const char* text, UINT& w, UINT& h) { return sscanf(text, "%ux%u", &w, &h) == 2 && w > 0 && h > 0; }

// "g22" and "pq" mean BT.709 gamma 2.2 / BT.2020 PQ, in the colour-space family of the format; otherwise a DXGI_COLOR_SPACE_TYPE number.
static bool parseColorSpace(const char* text, bool yuv, DXGI_COLOR_SPACE_TYPE& cs) {
    if (!strcmp(text, "g22")) { cs = yuv ? DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709; return true; }
    if (!strcmp(text, "pq"))  { cs = yuv ? DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020 : DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020; return true; }
    if (text[0] < '0' || text[0] > '9') return false;
    cs = (DXGI_COLOR_SPACE_TYPE)atoi(text); return true;
}

static void printUsage() {
    printf("usage: repro [--vsr 0|1] [--hdr 0|1] [--out ");
    for (size_t i = 0; i < sizeof kOutFormats / sizeof kOutFormats[0]; i++) printf("%s%s", i ? "|" : "", kOutFormats[i].name);
    puts("] [--in nv12|p010]\n"
         "             [--in-size WxH] [--out-size WxH] [--in-cs g22|pq|N] [--out-cs g22|pq|N]\n"
         "             [--frames N] [--mode check|stream] [--max-seconds N] [--wait-ms N]");
}

static bool parseArgs(int argc, char** argv, Options& o) {
    const char *in = "nv12", *outName = "rgb10a2", *inCs = nullptr, *outCs = nullptr, *outSize = nullptr, *inSize = nullptr;
    for (int i = 1; i < argc; i++) {
        const char* key = argv[i];
        const char* val = i + 1 < argc ? argv[i + 1] : nullptr;
        if (!strcmp(key, "--help") || !strcmp(key, "-h")) return false;
        if (!val) { printf("missing value for %s\n", key); return false; }
        i++;
        if (!strcmp(key, "--vsr")) o.vsr = atoi(val) != 0;
        else if (!strcmp(key, "--hdr")) o.hdr = atoi(val) != 0;
        else if (!strcmp(key, "--out")) outName = val;
        else if (!strcmp(key, "--in")) in = val;
        else if (!strcmp(key, "--in-size")) inSize = val;
        else if (!strcmp(key, "--out-size")) outSize = val;
        else if (!strcmp(key, "--in-cs")) inCs = val;
        else if (!strcmp(key, "--out-cs")) outCs = val;
        else if (!strcmp(key, "--frames")) o.frames = atoi(val);
        else if (!strcmp(key, "--mode")) { if (!strcmp(val, "check")) o.mode = Mode::Check; else if (!strcmp(val, "stream")) o.mode = Mode::Stream; else { printf("unknown mode %s\n", val); return false; } }
        else if (!strcmp(key, "--max-seconds")) o.maxSeconds = (ULONGLONG)atoi(val);
        else if (!strcmp(key, "--wait-ms")) o.waitMs = (DWORD)atoi(val);
        else { printf("unknown option %s\n", key); return false; }
    }

    for (const OutFormat& c : kOutFormats) if (!strcmp(outName, c.name)) o.out = &c;
    if (!o.out) { printf("unknown output format %s\n", outName); return false; }
    o.outCS = o.out->cs;

    if (!strcmp(in, "p010")) { o.p010 = true; o.inCS = DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020; }
    else if (strcmp(in, "nv12")) { printf("unknown input format %s\n", in); return false; }

    if (inSize && !parseSize(inSize, o.inW, o.inH)) { printf("bad --in-size %s (want WxH)\n", inSize); return false; }
    if (outSize) { if (!parseSize(outSize, o.outW, o.outH)) { printf("bad --out-size %s (want WxH)\n", outSize); return false; } }
    else if (o.out->yuv) { o.outW = o.inW; o.outH = o.inH; }
    else { o.outW = kDefaultOutW; o.outH = kDefaultOutH; }

    if (inCs && !parseColorSpace(inCs, true, o.inCS)) { printf("bad --in-cs %s\n", inCs); return false; }
    if (outCs && !parseColorSpace(outCs, o.out->yuv, o.outCS)) { printf("bad --out-cs %s\n", outCs); return false; }
    if (o.mode == Mode::Stream && o.out->yuv) { puts("--mode stream needs an RGB --out: a flip-model swap chain cannot be NV12/P010"); return false; }
    return true;
}

struct Gpu {
    ComPtr<IDXGIFactory2> factory;
    ComPtr<IDXGIAdapter3> adapter;
    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    ComPtr<ID3D11VideoDevice> vdev;
    ComPtr<ID3D11VideoContext1> vctx;
};

static int createGpu(Gpu& g) {
    CHK(CreateDXGIFactory1(IID_PPV_ARGS(&g.factory)));
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; g.factory->EnumAdapters1(i, &adapter) == S_OK; i++) {
        DXGI_ADAPTER_DESC1 d; adapter->GetDesc1(&d);
        if (d.VendorId == 0x10de) { wprintf(L"adapter: %s\n", d.Description); break; }
        adapter.Reset();
    }
    if (!adapter) { puts("no NVIDIA adapter"); return 3; }
    CHK(adapter.As(&g.adapter));
    CHK(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, 0, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                          0, 0, D3D11_SDK_VERSION, &g.dev, 0, &g.ctx));
    CHK(g.dev.As(&g.vdev)); CHK(g.ctx.As(&g.vctx));
    return 0;
}

struct Processor {
    ComPtr<ID3D11VideoProcessorEnumerator> en;
    ComPtr<ID3D11VideoProcessor> vp;
};

static int createProcessor(const Gpu& g, const Options& o, Processor& p) {
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd = {};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = o.inW; cd.InputHeight = o.inH; cd.OutputWidth = o.outW; cd.OutputHeight = o.outH;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    CHK(g.vdev->CreateVideoProcessorEnumerator(&cd, &p.en));
    CHK(g.vdev->CreateVideoProcessor(p.en.Get(), 0, &p.vp));
    g.vctx->VideoProcessorSetStreamColorSpace1(p.vp.Get(), 0, o.inCS);
    g.vctx->VideoProcessorSetOutputColorSpace1(p.vp.Get(), o.outCS);
    return 0;
}

// A pattern with edges and noise (not a smooth ramp), neutral chroma: plainly not black, and VSR visibly changes it.
static std::vector<unsigned char> makeInputPattern(UINT w, UINT h, bool p010) {
    std::vector<unsigned char> buf((size_t)w * h * 3 / 2 * (p010 ? 2 : 1));
    for (UINT y = 0; y < h; y++) for (UINT x = 0; x < w; x++) {
        unsigned r = (x * 73856093u) ^ (y * 19349663u); r ^= r >> 13; r *= 0x5bd1e995u; r ^= r >> 15;
        unsigned base = 80 + (x * 100) / w;
        unsigned v = ((x / 16 + y / 16) & 1) ? base + (r & 31) : base - 20 + ((x ^ y) & 15);
        if (p010) ((unsigned short*)buf.data())[y * w + x] = (unsigned short)(v << 8); else buf[y * w + x] = (unsigned char)v;
    }
    if (p010) { unsigned short* c = (unsigned short*)buf.data() + w * h; for (UINT i = 0; i < w * h / 2; i++) c[i] = 512 << 6; }
    else memset(buf.data() + w * h, 128, w * h / 2);
    return buf;
}

struct Surfaces {
    ComPtr<ID3D11Texture2D> inTex, outTex;
    ComPtr<ID3D11VideoProcessorInputView> iv;
    ComPtr<ID3D11VideoProcessorOutputView> ov;
};

static D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC inputViewDesc(UINT arraySlice = 0) {
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC d = {}; d.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D; d.Texture2D.ArraySlice = arraySlice; return d;
}
static D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC outputViewDesc() {
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC d = {}; d.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D; return d;
}

static int createSurfaces(const Gpu& g, const Options& o, const Processor& p, Surfaces& s) {
    std::vector<unsigned char> pattern = makeInputPattern(o.inW, o.inH, o.p010);
    D3D11_TEXTURE2D_DESC td = {}; td.Width = o.inW; td.Height = o.inH; td.MipLevels = 1; td.ArraySize = 1; td.SampleDesc.Count = 1;
    td.Format = o.p010 ? DXGI_FORMAT_P010 : DXGI_FORMAT_NV12; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    UINT support = 0; p.en->CheckVideoProcessorFormat(td.Format, &support);
    printf("input %s VP support flags=0x%x\n", o.p010 ? "P010" : "NV12", support);
    D3D11_SUBRESOURCE_DATA init = {pattern.data(), o.inW * (o.p010 ? 2u : 1u), 0};
    CHK(g.dev->CreateTexture2D(&td, &init, &s.inTex));
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = inputViewDesc();
    CHK(g.vdev->CreateVideoProcessorInputView(s.inTex.Get(), p.en.Get(), &ivd, &s.iv));

    td.Width = o.outW; td.Height = o.outH; td.Format = o.out->fmt; td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    CHK(g.dev->CreateTexture2D(&td, 0, &s.outTex));
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = outputViewDesc();
    CHK(g.vdev->CreateVideoProcessorOutputView(s.outTex.Get(), p.en.Get(), &ovd, &s.ov));
    return 0;
}

// Asks the driver for VSR and TrueHDR on stream 0 and returns the two answers.
struct ExtensionResults { HRESULT vsr, hdr; };
static ExtensionResults sendExtensions(const Gpu& g, const Processor& p, const Options& o) {
    NvExt vsr = {kExtensionVersion, kVsrMethod, o.vsr ? 1u : 0u};
    NvHdrExt hdr = {kTrueHdrVersion, kTrueHdrMethod, o.hdr ? 1u : 0u, 0u};
    ExtensionResults r;
    r.vsr = g.vctx->VideoProcessorSetStreamExtension(p.vp.Get(), 0, &kNvPPE, sizeof(vsr), &vsr);
    r.hdr = g.vctx->VideoProcessorSetStreamExtension(p.vp.Get(), 0, &kNvTrueHDR, sizeof(hdr), &hdr);
    return r;
}

// Once, before streaming or blitting: asks whether TrueHDR is supported, sends the extensions and prints all three answers.
static void announceExtensions(const Gpu& g, const Processor& p, const Options& o) {
    UINT supported = 0;
    HRESULT hs = g.vctx->VideoProcessorGetStreamExtension(p.vp.Get(), 0, &kNvTrueHDR, sizeof(supported), &supported);
    ExtensionResults r = sendExtensions(g, p, o);
    printf("SetStreamExtension VSR (ver=%u method=%u enable=%u) -> 0x%08lx\n", kExtensionVersion, kVsrMethod, o.vsr ? 1u : 0u, (unsigned long)r.vsr);
    printf("TrueHDR support query -> 0x%08lx value=%u\n", (unsigned long)hs, supported);
    printf("SetStreamExtension TrueHDR (ver=%u method=%u enable=%u) -> 0x%08lx\n", kTrueHdrVersion, kTrueHdrMethod, o.hdr ? 1u : 0u, (unsigned long)r.hdr);
}

static int blit(const Gpu& g, const Processor& p, ID3D11VideoProcessorOutputView* ov, ID3D11VideoProcessorInputView* iv, UINT outputFrame, int frame) {
    D3D11_VIDEO_PROCESSOR_STREAM st = {}; st.Enable = TRUE; st.pInputSurface = iv;
    HRESULT h = g.vctx->VideoProcessorBlt(p.vp.Get(), ov, outputFrame, 1, &st);
    if (h != S_OK) { printf("Blt frame %d -> 0x%08lx\n", frame, (unsigned long)h); return 3; }   // "returns S_OK" in the reports means exactly this
    return 0;
}

// Check mode: blit the same input `frames` times into one output surface.
static int runBlits(const Gpu& g, const Processor& p, const Options& o, const Surfaces& s) {
    for (int f = 0; f < o.frames; f++) {
        if (int rc = blit(g, p, s.ov.Get(), s.iv.Get(), f, f)) return rc;
        g.ctx->Flush();
    }
    return 0;
}

// A flip-model swap chain on a hidden, off-screen window: the swap chain is real but nothing is ever drawn on the user's screen.
static int createHiddenSwapChain(const Gpu& g, const Options& o, ComPtr<IDXGISwapChain1>& swap) {
    WNDCLASSW wc = {}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(0); wc.lpszClassName = L"vsrrepro"; RegisterClassW(&wc);
    HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"vsrrepro", L"vsr", WS_POPUP, -32000, -32000, o.outW, o.outH, 0, 0, wc.hInstance, 0);
    if (!hwnd) { printf("CreateWindow failed %lu\n", GetLastError()); return 3; }
    DXGI_SWAP_CHAIN_DESC1 scd = {}; scd.Width = o.outW; scd.Height = o.outH; scd.Format = o.out->fmt; scd.SampleDesc.Count = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; scd.BufferCount = 3; scd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    CHK(g.factory->CreateSwapChainForHwnd(g.dev.Get(), hwnd, &scd, 0, 0, &swap));
    return 0;
}

// This process's own video-memory use as the OS accounts it (includes what the driver allocates for us), and the
// cap at which stream mode stops: a third of the GPU memory budget but at most kCapMaxMb.
static const ULONGLONG kCapMaxMb = 6000;
struct VramMeter {
    ComPtr<IDXGIAdapter3> adapter;
    ULONGLONG capMb = 0, budgetMb = 0;

    void init(const Gpu& g) {
        adapter = g.adapter;
        DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
        adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info);
        budgetMb = info.Budget >> 20;
        capMb = budgetMb / 3; if (capMb > kCapMaxMb) capMb = kCapMaxMb;
    }
    ULONGLONG usageMb() const {
        DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
        adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info);
        return (ULONGLONG)(info.CurrentUsage >> 20);
    }
};

// Stream mode: what a browser's video path does each frame, to watch the driver's memory use.
// Stops by itself, after --max-seconds or when this process uses the VRAM cap: a leaking driver must not fill the GPU.
static int runStream(const Gpu& g, const Processor& p, const Options& o) {
    announceExtensions(g, p, o);
    D3D11_TEXTURE2D_DESC ad = {}; ad.Width = o.inW; ad.Height = o.inH; ad.MipLevels = 1; ad.ArraySize = kDecoderArraySize; ad.Format = DXGI_FORMAT_NV12; ad.SampleDesc.Count = 1;
    ad.Usage = D3D11_USAGE_DEFAULT; ad.BindFlags = D3D11_BIND_DECODER | D3D11_BIND_SHADER_RESOURCE;   // decoder-style array, left uninitialised
    ComPtr<ID3D11Texture2D> decoderArray; CHK(g.dev->CreateTexture2D(&ad, 0, &decoderArray));

    ComPtr<IDXGISwapChain1> swap; if (int rc = createHiddenSwapChain(g, o, swap)) return rc;
    VramMeter vram; vram.init(g);
    printf("stream: process VRAM from DXGI, cap %llu MB (budget %llu MB), max %llu s; one line per second\n", vram.capMb, vram.budgetMb, o.maxSeconds);
    const ULONGLONG start = GetTickCount64(); ULONGLONG nextReport = 0;
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = outputViewDesc();
    const char* reason = "frames";
    int f = 0;
    for (; f < o.frames; f++) {
        const ULONGLONG elapsed = GetTickCount64() - start;
        if (elapsed >= nextReport) { printf("stream t=%.1f frame=%d vram_mb=%llu\n", elapsed / 1000.0, f, vram.usageMb()); fflush(stdout); nextReport += 1000; }
        if (elapsed > o.maxSeconds * 1000ull) { reason = "max-seconds"; break; }
        if (vram.usageMb() > vram.capMb) { reason = "vram-cap"; break; }
        Sleep(kStreamFrameMs);
        sendExtensions(g, p, o);
        ComPtr<ID3D11Texture2D> backBuffer; CHK(swap->GetBuffer(0, IID_PPV_ARGS(&backBuffer)));
        ComPtr<ID3D11VideoProcessorOutputView> ov; CHK(g.vdev->CreateVideoProcessorOutputView(backBuffer.Get(), p.en.Get(), &ovd, &ov));
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = inputViewDesc(f % kDecoderArraySize);
        ComPtr<ID3D11VideoProcessorInputView> iv; CHK(g.vdev->CreateVideoProcessorInputView(decoderArray.Get(), p.en.Get(), &ivd, &iv));
        if (int rc = blit(g, p, ov.Get(), iv.Get(), 0, f)) return rc;
        HRESULT hp = swap->Present(0, 0); if (FAILED(hp)) { printf("Present frame %d -> 0x%08lx\n", f, (unsigned long)hp); return 3; }
        MSG msg; while (PeekMessageW(&msg, 0, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    printf("stream end t=%.1f frame=%d vram_mb=%llu reason=%s\n", (GetTickCount64() - start) / 1000.0, f, vram.usageMb(), reason);
    return 0;
}

// ---- reading the output back -------------------------------------------------------------------------------

struct Stats { double sum = 0; long n = 0; unsigned maxv = 0; unsigned long long hash = 1469598103934665603ull; };
static void add(Stats& s, unsigned v) { s.sum += v; s.n++; if (v > s.maxv) s.maxv = v; }

// Mean/max over the luma plane (YUV: chroma is only hashed, so a zeroed chroma plane alone is not reported as black)
// or a 16-row strip through the middle (RGB). For RGB the value is the per-pixel R+G+B sum.
static void measure(const Options& o, const D3D11_MAPPED_SUBRESOURCE& m, Stats& s) {
    auto rowAt = [&](UINT y) { return (const unsigned char*)m.pData + (size_t)y * m.RowPitch; };
    if (o.out->yuv) {
        for (UINT y = 0; y < o.outH; y++) for (UINT x = 0; x < o.outW; x++) {
            unsigned v = o.out->bps == 2 ? ((const unsigned short*)rowAt(y))[x] : rowAt(y)[x];
            add(s, v);
        }
        return;
    }
    const UINT top = o.outH < 16 ? 0 : o.outH / 2 - 8, bottom = o.outH < 16 ? o.outH : o.outH / 2 + 8;   // all rows if fewer than 16
    for (UINT y = top; y < bottom; y++) for (UINT x = 0; x < o.outW; x += 4) {
        unsigned p = ((const unsigned*)rowAt(y))[x];   // R10G10B10A2
        add(s, (p & 0x3ff) + ((p >> 10) & 0x3ff) + ((p >> 20) & 0x3ff));
    }
}

// FNV-1a over the whole surface (luma rows then chroma rows for YUV), so any change in the output shows in the hash.
static void hashSurface(const Options& o, const D3D11_MAPPED_SUBRESOURCE& m, Stats& s) {
    const UINT rows = o.out->yuv ? o.outH * 3 / 2 : o.outH;
    const size_t bytesPerPixel = o.out->yuv ? o.out->bps : 4;
    for (UINT y = 0; y < rows; y++) {
        const unsigned char* row = (const unsigned char*)m.pData + (size_t)y * m.RowPitch;
        for (size_t i = 0; i < o.outW * bytesPerPixel; i++) { s.hash ^= row[i]; s.hash *= 1099511628211ull; }
    }
}

static int readbackAndReport(const Gpu& g, const Options& o, const Surfaces& s) {
    D3D11_TEXTURE2D_DESC sd; s.outTex->GetDesc(&sd);
    sd.BindFlags = 0; sd.Usage = D3D11_USAGE_STAGING; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging; CHK(g.dev->CreateTexture2D(&sd, 0, &staging));
    g.ctx->CopyResource(staging.Get(), s.outTex.Get());
    D3D11_MAPPED_SUBRESOURCE m; CHK(g.ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &m));
    Stats st; measure(o, m, st); hashSurface(o, m, st);
    g.ctx->Unmap(staging.Get(), 0);

    const bool black = st.maxv == 0;
    printf("HASH %016llx\n", st.hash);
    printf("RESULT vsr=%d hdr=%d out=%s %s=%.1f max=%u -> %s\n", o.vsr, o.hdr, o.out->name, o.out->yuv ? "mean_luma" : "mean_rgb_sum", st.sum / st.n, st.maxv, black ? "BLACK" : "ok");
    return black ? 2 : 0;
}

// Check mode: the known pattern blitted `frames` times into one output surface, read back and reported.
static int runCheck(const Gpu& g, const Processor& p, const Options& o) {
    Surfaces s; if (int rc = createSurfaces(g, o, p, s)) return rc;
    announceExtensions(g, p, o);
    if (int rc = runBlits(g, p, o, s)) return rc;
    return readbackAndReport(g, o, s);
}

int main(int argc, char** argv) {
    Options o;
    if (!parseArgs(argc, argv, o)) { printUsage(); return 1; }
    if (o.waitMs) Sleep(o.waitMs);   // time to attach a debugger
    Gpu gpu; if (int rc = createGpu(gpu)) return rc;
    Processor proc; if (int rc = createProcessor(gpu, o, proc)) return rc;
    return o.mode == Mode::Stream ? runStream(gpu, proc, o) : runCheck(gpu, proc, o);
}

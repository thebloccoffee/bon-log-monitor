// Answers one question: does Sony's Camera Remote SDK work with the ORIGINAL ZV-E10?
// (Sony only lists the ZV-E10 II.) Lists cameras, then connects to the first one,
// reads exposure settings and saves one live view frame to liveview.jpg.
//
//   ./build.sh probe
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <thread>
#include <vector>

#include "CameraRemote_SDK.h"
#include "IDeviceCallback.h"

namespace SDK = SCRSDK;

struct Callback : SDK::IDeviceCallback {
    std::atomic<bool> connected{false};
    std::atomic<int> disconnectedError{-1};
    void OnConnected(SDK::DeviceConnectionVersioin) override { connected = true; std::puts("  OnConnected"); }
    void OnDisconnected(CrInt32u e) override { disconnectedError = (int)e; std::printf("  OnDisconnected 0x%X\n", e); }
    void OnError(CrInt32u e) override { std::printf("  OnError 0x%X\n", e); }
    void OnWarning(CrInt32u w) override { std::printf("  OnWarning 0x%X\n", w); }
};

static const char* propName(CrInt32u code) {
    switch (code) {
        case SDK::CrDeviceProperty_FNumber: return "FNumber";
        case SDK::CrDeviceProperty_IsoSensitivity: return "ISO";
        case SDK::CrDeviceProperty_ShutterSpeed: return "ShutterSpeed";
        case SDK::CrDeviceProperty_WhiteBalance: return "WhiteBalance";
        case SDK::CrDeviceProperty_ExposureBiasCompensation: return "ExposureComp";
        case SDK::CrDeviceProperty_PictureProfile: return "PictureProfile";
        case SDK::CrDeviceProperty_RecordingState: return "RecordingState";
        default: return nullptr;
    }
}

// argv[1] (optional): the camera's 12-char USB serial. When the search finds nothing
// (the original ZV-E10 isn't on Sony's model list), we build the camera object
// directly and claim the closest supported model, the ZV-E10 II.
int main(int argc, char** argv) {
    if (!SDK::Init()) { std::puts("SDK Init failed"); return 1; }
    std::puts("Searching for cameras (USB + network, 5s)...");
    SDK::ICrEnumCameraObjectInfo* list = nullptr;
    SDK::ICrCameraObjectInfo* forced = nullptr;
    const SDK::ICrCameraObjectInfo* info = nullptr;
    auto err = SDK::EnumCameraObjects(&list, 5);
    if (CR_SUCCEEDED(err) && list && list->GetCount() > 0) {
        for (CrInt32u i = 0; i < list->GetCount(); i++) {
            auto* c = list->GetCameraObjectInfo(i);
            std::printf("[%u] model=%s connection=%s ssh=%u pairing=%s\n", i + 1, c->GetModel(),
                        c->GetConnectionTypeName(), c->GetSSHsupport(), c->GetPairingNecessity());
        }
        info = list->GetCameraObjectInfo(0);
    } else {
        std::printf("Search found no supported cameras (0x%X).\n", (unsigned)err);
        if (argc < 2 || std::strlen(argv[1]) != 12) {
            std::puts("No USB serial given, so no direct attempt. Camera menu: Network > Smartphone Connect OFF,");
            std::puts("PC Remote Function > PC Remote ON, connection method USB.");
            SDK::Release();
            return 2;
        }
        CrInt8u serial[13] = {};
        std::memcpy(serial, argv[1], 12);
        std::printf("Trying direct USB connection to serial %s as ZV-E10M2...\n", argv[1]);
        err = SDK::CreateCameraObjectInfoUSBConnection(&forced, SDK::CrCameraDeviceModel_ZV_E10M2, serial);
        if (CR_FAILED(err) || !forced) {
            std::printf("CreateCameraObjectInfoUSBConnection failed: 0x%X\n", (unsigned)err);
            SDK::Release();
            return 2;
        }
        info = forced;
    }

    auto cleanup = [&] {
        if (list) list->Release();
        if (forced) forced->Release();
        SDK::Release();
    };
    Callback cb;
    SDK::CrDeviceHandle handle = 0;
    std::printf("Connecting to %s...\n", info->GetModel());
    err = SDK::Connect(const_cast<SDK::ICrCameraObjectInfo*>(info), &cb, &handle,
                       SDK::CrSdkControlMode_Remote, SDK::CrReconnecting_ON);
    if (CR_FAILED(err)) {
        std::printf("Connect failed: 0x%X\n", (unsigned)err);
        cleanup();
        return 3;
    }
    for (int i = 0; i < 150 && !cb.connected && cb.disconnectedError < 0; i++)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (!cb.connected) {
        std::puts("Never got OnConnected — the SDK doesn't accept this camera (or pairing was not confirmed).");
        SDK::ReleaseDevice(handle);
        cleanup();
        return 4;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));

    SDK::CrDeviceProperty* props = nullptr;
    CrInt32 n = 0;
    if (CR_SUCCEEDED(SDK::GetDeviceProperties(handle, &props, &n))) {
        std::printf("%d device properties reported. Exposure-related:\n", n);
        for (CrInt32 i = 0; i < n; i++) {
            const char* name = propName(props[i].GetCode());
            if (!name) continue;
            std::printf("  %-15s current=0x%llX settable=%d options=%u bytes\n", name,
                        (unsigned long long)props[i].GetCurrentValue(), props[i].IsSetEnableCurrentValue(),
                        props[i].GetValueSize());
        }
        SDK::ReleaseDeviceProperties(handle, props);
    } else {
        std::puts("GetDeviceProperties failed");
    }

    SDK::CrImageInfo inf;
    bool saved = false;
    for (int attempt = 0; attempt < 20 && !saved; attempt++) {
        if (CR_FAILED(SDK::GetLiveViewImageInfo(handle, &inf)) || inf.GetBufferSize() == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        std::vector<CrInt8u> buf(inf.GetBufferSize());
        SDK::CrImageDataBlock block;
        block.SetSize((CrInt32u)buf.size());
        block.SetData(buf.data());
        auto e = SDK::GetLiveViewImage(handle, &block);
        if (CR_SUCCEEDED(e) && block.GetImageSize() > 0) {
            std::ofstream("liveview.jpg", std::ios::binary)
                .write((const char*)block.GetImageData(), block.GetImageSize());
            std::printf("Live view frame saved: liveview.jpg (%u bytes)\n", block.GetImageSize());
            saved = true;
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    }
    if (!saved) std::puts("No live view frame received.");

    SDK::Disconnect(handle);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    SDK::ReleaseDevice(handle);
    cleanup();
    std::puts(saved ? "RESULT: SDK works with this camera." : "RESULT: connected, but live view failed.");
    return saved ? 0 : 5;
}

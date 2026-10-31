# Bon Log Monitor

Created by **@jooonbon**.

A macOS field monitor for Sony cameras shooting S-Log. Plug the camera in over USB and see its live view converted to Rec.709, with exposure tools, touch focus, audio meters and full exposure control, mirrored to your phone over Wi-Fi.

## Features

- **Live view** over USB or Wi-Fi with a log ↔ Rec.709 toggle: S-Log3 / S-Gamut3.Cine, S-Log3 / S-Gamut3, S-Log2 / S-Gamut.
- **Exposure tools** on the Rec.709 image: zebras (above a level or a range), false color, skin-tone band.
- **Camera control** from the readout bar: iris, shutter, ISO, white balance, focus mode, focus area, picture profile, record with timer.
- **Touch focus**: click the picture (or tap it on your phone) and the camera reacts as if you touched its own screen (Sony RemoteTouch). In MF it does a one-shot AF on that spot; in AF it moves the spot / starts tracking per your camera's touch settings.
- **Audio meters**: per-channel level meters with peak hold, from any Mac audio input (camera HDMI into a capture card, or USB Streaming).
- **Phone view**: scan the QR code in the sidebar to monitor and control from Safari. Local network only, no authentication.
- **Demo mode**: play an S-Log clip from disk or a built-in S-Log3 test chart.

Keys: `L` Rec.709 · `Z` zebra · `F` false color · `S` skin · `A` audio · `R` record · `B` sidebar.

## Install (ready-made app)

1. Install [Homebrew](https://brew.sh), then libgphoto2: `brew install gphoto2`
2. Download `Bon-Log-Monitor.zip` from the [latest release](../../releases/latest), unzip, and drag **Bon Log Monitor** to Applications.
3. The app isn't notarized by Apple, so the first time: right-click it → **Open** → **Open**. (Or run `xattr -dr com.apple.quarantine "/Applications/Bon Log Monitor.app"`.)

Apple silicon Macs only (it links Homebrew's libgphoto2 in `/opt/homebrew`).

## Build from source

### Requirements

- macOS 13+ on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) and libgphoto2: `brew install gphoto2`

### Build and run

```sh
./build.sh          # builds .build/manual/Bon Log Monitor.app
./build.sh run      # builds and opens it
./build.sh check    # builds and runs the self-check (color math, GPU vs CPU)
```

## Connecting the camera

1. On the camera, set **USB Connection** to **PC Remote**.
2. Plug it in over USB and launch the app. It connects automatically and reconnects after a replug.
3. Quit Photos / Image Capture if either is holding the camera.

For touch focus, set **Touch Operation** On and **Touch Func. in Shooting** to Touch Focus on the camera.

PC Remote over USB carries no audio (verified on the FX3: no audio levels in any property or in the live view data). For the camera's own audio on the meters, run its HDMI out into a capture card and pick the card under **Audio** in the sidebar.

## Connecting over Wi-Fi

USB has lower latency. Over Wi-Fi the FX3 sends the same 1024×576 live view at about 17 fps, with a little more delay that depends on your network.

1. On the camera, join the same Wi-Fi as the Mac: **Network → Wi-Fi → Access Point Set**.
2. **Network → PC Remote Function**: PC Remote **On**, Connection Method **Wi-Fi Access Point Connection**.
3. **Network → Network Option → Access Authen. Settings**: Access Authen. **Off**. With it on, the camera only accepts Sony's own login, which the app can't do.
4. In the app sidebar, set Source to **Sony camera (Wi-Fi)** and press **Find** (or type the camera's IP).
5. First time only: press **Pair…**, then on the camera choose **PC Remote Function → Pairing** and confirm. The camera remembers this Mac after that.

The app remembers the source and IP, so it reconnects on its own next launch. If the camera stops answering, turn it off and on.

## Tested cameras

- Sony **FX3** (firmware 7.02): live view, exposure control, touch focus, over USB and Wi-Fi.

Other Sony bodies that libgphoto2 supports in PC Remote mode should work; reports and PRs welcome.

## Picture profiles

Automatic curve selection uses the ZV-E10 PP layout (PP7 = S-Log2, PP8 = S-Log3 / S-Gamut3.Cine, PP9 = S-Log3 / S-Gamut3). On FX3 / FX30 (or Cine EI), turn off "Follow camera picture profile" and pick the curve in the sidebar.

## License

MIT (see LICENSE). libgphoto2 is LGPL-2.1, linked dynamically from Homebrew.

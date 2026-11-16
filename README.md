# Real-time Ambilight with the Action "LSC Smart Connect HDMI Sync Box" (OpenBeken + Hyperion)

*Version française : [README.fr.md](README.fr.md)*

Drive the LED strip of the Action "LSC Smart Connect HDMI Sync Box" (Action ref. 3017060, model 6204000100, Eurodomest, Tuya based) in real time from [Hyperion.NG](https://hyperion-project.org/), without using the box's own HDMI processing. In the setup described here the image comes from an LG OLED webOS TV (PicCap / hyperion-webos), so native apps such as Netflix are covered too. Other Hyperion sources have not been tested yet.

```
TV (PicCap, port 19400) -> Hyperion.NG -> udpddp (DDP, UDP 4048) -> sync box under OpenBeken -> LED strip
```

Status: working end to end (tested with solid colours, single pixels, rainbow, and live video). This is a hobby project, tested on a single unit.

## What is in this repository

| Path | Content |
|------|---------|
| `patches/openbeken-1.18.219-ws2811bb.patch` | Adds a `WS2811BB` driver to OpenBeken 1.18.219 (`OpenBK7231T_App`). |
| `patches/openbeken-main-168cba5-ws2811bb.patch` | The same driver ported to OpenBeken `main` (commit 168cba5, 6 Nov 2026): applies cleanly and compiles. Use this one for upstream work. |
| `patches/sdk-OpenBK7231N-itcm.patch` | One line in the BK7231N SDK linker script, to place the send loop in ITCM. |
| `Dockerfile` | Build environment (Ubuntu 22.04 + ARM toolchain). |

No firmware binary is distributed: OpenBeken and its SDK (`openshwprojects/OpenBK7231N`, Tuya/Beken code) declare no licence, so you build it yourself.

## Why a new driver

The box contains an ESP32 (HDMI image processing) and a BK7231N / CBU module (Tuya cloud and LED strip). Teardown: [elektroda 4090571](https://www.elektroda.com/rtvforum/topic4090571.html). The LED data line has these properties, found in [elektroda 4123137](https://www.elektroda.com/rtvforum/topic4123137.html):

- On the BK7231N, **P0 and P8 are the two inputs of a NOR gate** whose output is the strip data line. **P8 must be held low**, and **the data goes out on P0**.
- The signal is **inverted WS2812B**: idle high, pulses low.
- P0 is UART2_TXD, so SPI cannot be used on it. Hence a bit-banged driver.

The `WS2811BB` driver writes the GPIO configuration register directly, with interrupts disabled during one frame. The send loop is placed in ITCM through the linker script, because code running from flash gets random wait states that ruin the pulse widths, and code running from `.data` RAM crashed the box (watchdog). **The SDK patch is not optional**: we built the driver without the ITCM line and, with Hyperion streaming frames over DDP, the strip visibly flickered (observed by eye; a loop-iteration measurement gave about 87 ns instead of about 55 ns with ITCM, from our notes). The driver plugs into OpenBeken's shared LED layer, so `SM16703P_Init`, `SM16703P_SetPixel`, `SM16703P_Start` and the DDP driver work on top of it.

Commands:

- `WS2811BB_Timing n0h n0l n1h n1l`: bit timing in loop iterations (about 55 ns each here).
- `WS2811BB_Invert 0|1`: default 1 (idle high, pulses low).
- `WS2811BB_Calib`: measures the real bit period, result in `/lograw`.

Limits: one frame is at most 450 bytes (150 RGB pixels), because it is sent with interrupts disabled. BK7231N only.

## Hardware notes

- Strip: **12 V**, 1.5 A max (labels), **28 circuits of 3 LEDs, so 28 pixels**, colour order GRB. **Never plug the strip's USB connector into a normal USB port** (it carries 12 V).
- The strip's USB connector can make poor contact; a moving contact causes flicker and random states that look like software bugs. Secure it (adhesive tape) before debugging.
- Flashing the box with CloudCutter **erases the original Tuya firmware, and no backup is possible with that method**. Accept that before you start.

## Step by step

### 1. Flash OpenBeken

Use [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter) with the profile `lsc-3017060-hdmi-light-sync-box-v1.0.7`, then put the box on your network.

### 2. Build the patched firmware

```sh
git clone --depth 1 --branch 1.18.219 https://github.com/openshwprojects/OpenBK7231T_App.git
cd OpenBK7231T_App
git submodule update --init --depth 1 libraries/berry sdk/OpenBK7231N
git apply ../patches/openbeken-1.18.219-ws2811bb.patch
(cd sdk/OpenBK7231N && git apply ../../../patches/sdk-OpenBK7231N-itcm.patch)

docker build --platform linux/amd64 -t obk-build-x86 - < ../Dockerfile
docker run --rm --platform linux/amd64 -v "$PWD:/src" obk-build-x86 bash -c \
  'git config --global --add safe.directory "*"; make APP_VERSION=1.18.219 APP_NAME=OpenBK7231N VARIANT=default OpenBK7231N'
```

Result: `output/1.18.219/OpenBK7231N_1.18.219.rbl`. The build was checked on a clean tag: it compiles, and the uncompressed `.bin` differs from the first build only by a handful of bytes (build date).

### 3. Update over the air

```sh
curl -X POST --data-binary @OpenBK7231N_1.18.219.rbl http://<box-ip>/api/ota
sleep 30        # restarting too early (about 6 s) leaves the old version
curl "http://<box-ip>/index?restart=1"
```

Check the build date in `http://<box-ip>/api/info`. Rollback: flash the official OpenBeken 1.18.219 `.rbl` the same way.

### 4. Configure the pins and the startup command

Pin roles (stored permanently): `UCS1912_DIN` on **P0** (data) and `AlwaysLow` on **P8**. Note that setting a role back to `None` does not always release the pin until a reboot.

Startup command (the box restores its ambient light by itself after a reboot):

```
backlog startDriver WS2811BB; SM16703P_Init 28 GRB; WS2811BB_Timing 4 13 12 4; startDriver DDP; SM16703P_SetPixel all 204 117 33; SM16703P_Start
```

`WS2811BB_Timing 4 13 12 4` worked on our unit. Use `WS2811BB_Calib` and your own measurements if your strip behaves differently. The commands are sent as `http://<box-ip>/cm?cmnd=<command>`.

### 5. Configure Hyperion.NG (2.2.1)

LED device type **`udpddp`** (not `ddp`), host = box IP, port 4048, 28 LEDs, **colour order `rbg`** (the box's DDP path swaps green and blue, so Hyperion has to compensate). Lay the LEDs out in physical order along the strip.

API pitfalls if you script it over the JSON API (port 19444):

- Authenticate, then `instance switchTo 0`, otherwise `color` commands succeed with no effect.
- `config setconfig` needs the full configuration returned by `getconfig`.
- `color` accepts a single `[r,g,b]` for the whole strip; do not pass `duration: 0`.
- `rewriteTime` is forbidden for `udpddp`; `enableAttempts` and `enableAttemptsInterval` are mandatory.

Ambient light with the TV off: enable Hyperion's `backgroundEffect` (type `color`) with the same value as the startup command. Hyperion does not refresh a static colour periodically, which is why the startup command exists.

### 6. PicCap on the LG TV

Installed from the Homebrew Channel. Settings that worked on an OLED55G4: resolution **128x78**, 30 fps max, VSync off, video engine **`libvtcapture`**, graphics engine `libhalgal`. `libdile_vt` captures only the menus on this TV.

- **Latency:** with larger frames (320x180, 256x144) the TV's Wi-Fi saturated (about 3 MB/s) and the lag reached 1 to 2 s. At 128x78 the stream is about 0.9 MB/s and the lag is no longer noticeable. If lag returns, use Ethernet on the TV.
- **After standby or reboot**, PicCap may capture menus but not video (black video frames). Opening PicCap and pressing **Save** restarts the capture service.
- **Do not change PicCap settings while the capture is running**: it crashed Hyperion (SIGSEGV) for us. Stop Hyperion, change and save, start Hyperion.

## Credits

- **emarck**, for the P0 / P8 pinout and the inverted WS2812B finding ([elektroda 4123137](https://www.elektroda.com/rtvforum/topic4123137.html)).
- The [OpenBeken](https://github.com/openshwprojects/OpenBK7231T_App) project and its contributors; the thread moderator p.kaczmarek2 asked for a bit-banged driver with the send function in RAM.
- [Hyperion.NG](https://hyperion-project.org/), [PicCap / hyperion-webos](https://repo.webosbrew.org/apps/org.webosbrew.piccap/), [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter).
- Teardown: [elektroda 4090571](https://www.elektroda.com/rtvforum/topic4090571.html).

## AI assistance

This project was developed with the help of Claude Code (Anthropic), used for analysis, code, build scripts and documentation. All results were checked on real hardware.

## Licence

The patches, the Dockerfile and the documentation in this repository are released under the [MIT License](LICENSE). OpenBeken and its SDK have no declared licence at the time of writing; this repository contains none of their code except the context lines of the patches, and the MIT licence applies only to what we added.

## Disclaimer

You flash and wire this at your own risk: the original firmware is lost after CloudCutter, the strip runs on 12 V, and wrong timings or wiring can leave the strip in a random state.

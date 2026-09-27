# Luma

A native macOS and Linux controller for Elgato Key Lights. Luma uses one Zig backend and a lightweight platform webview: WKWebView on macOS and WebKitGTK on Linux. It opens as a normal desktop window—never as a browser tab.

## Features

- One-click power control
- Brightness from 3–100%
- Correct 2900–7000 K color-temperature conversion
- Sliders preview while dragging and send only once when released
- Night, Warm, Studio, and Daylight scenes
- Live state synchronization
- Device, firmware, Wi-Fi, and signal information
- Identify-light command
- Direct local communication; no cloud, browser, external assets, or telemetry

## Downloads

Every tagged GitHub release automatically publishes four native packages:

- macOS Apple Silicon (`arm64`)
- macOS Intel (`x86_64`)
- Linux ARM64
- Linux x86_64

Download them from the [Releases page](https://github.com/saiemsaeed/luma-key-light/releases).

## macOS

Requires Zig 0.16 or newer when building from source.

```sh
./scripts/package-macos.sh
open dist/Luma.app
```

You can copy `dist/Luma.app` to `/Applications` and launch it normally.

For development:

```sh
zig build run
```

## Linux

Released Linux binaries require GTK 3 and WebKitGTK 4.1 at runtime. Install the development packages below only when building from source.

Ubuntu/Debian:

```sh
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev
```

Fedora:

```sh
sudo dnf install webkit2gtk4.1-devel gtk3-devel
```

Then build and install Luma:

```sh
./scripts/install-linux.sh
```

It will appear in the desktop application launcher.

## Publishing a release

Push a version tag and GitHub Actions will test, package, and attach all four binaries automatically:

```sh
git tag v0.2.0
git push origin v0.2.0
```

## Options

```text
--host HOST          Light hostname or IP
--device-port PORT   Light API port (default: 9123)
--port PORT          Internal loopback port (default: 9473)
--headless           Run the backend without opening a window
```

If `.local` resolution is unavailable on Linux, launch with the light's IP:

```sh
luma --host 192.168.x.x
```

## Architecture

```text
Native window (WKWebView / WebKitGTK)
                │ loopback JSON API
                ▼
          Zig executable
                │ HTTP :9123
                ▼
          Elgato Key Light
```

The UI, device protocol, and loopback server are embedded into one executable. The internal server binds only to `127.0.0.1` and exists solely as the boundary between the native webview UI and Zig core.

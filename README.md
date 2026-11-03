# Xiaomi Pad Keyboard Cover Engine

[![Magisk](https://img.shields.io/badge/Magisk-v24+-brightgreen.svg)](https://github.com/topjohnwu/Magisk)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-blue.svg)](https://kernelsu.org)
[![APatch](https://img.shields.io/badge/APatch-Supported-orange.svg)](https://apatch.dev)
[![Android](https://img.shields.io/badge/Android-11%20--%2015-success.svg)](https://android.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight, kernel-integrated Magisk / KernelSU / APatch module that fixes magnetic pogo-pin official keyboard covers on Xiaomi Pad tablets running HyperOS, MIUI, or AOSP-based custom ROMs (Android 11 through Android 15).

Developed by **xoxye**.

---

## 🌟 Key Features

- **Cold Boot Lockscreen & Direct Boot (FBE) Security:** Physical keyboard initializes seamlessly without crashing or hanging input services.
- **Zero Reconnects After Reboot:** On cold boot with the keyboard attached, typing works immediately on the home screen right after entering your initial PIN without ever requiring you to physically disconnect and reconnect the cover.
- **Instant Hotplug & Virtual Keyboard Synchronization:** 
  - Magnetically detaching the cover unbinds hardware interfaces within **0.75s**, instantly bringing up your on-screen keyboard (Gboard, SwiftKey, Yandex Keyboard, etc.).
  - Reattaching the cover binds USB-HID in under **0.25s**, instantly restoring physical keystrokes and touchpad gestures.
- **Zero Hardware Dropouts:** Locks USB power management into persistent `on` mode with autosuspend disabled (`-1`), preventing MCU sleep during inactivity or typing pauses.
- **Adaptive Screen-Off Power Management:** 
  - Screen ON: polls every `0.25s` for instant detach response.
  - Screen OFF: dynamically backs off to `5.0s` with dual Backlight + DRM DPMS detection to preserve battery and allow the device to enter uninterrupted **Deep Sleep**.
- **Ultra-Lightweight (Zero-Fork Architecture):** Uses native POSIX shell built-ins with zero child process overhead (`0.2% CPU of 1 core`, `< 800 KB RAM`).
- **CLI Management Tool (`kb`):** Full diagnostic suite, live connection testing, and manual override directly from terminal.

---

## 📱 Supported Devices

| Device Codename | Commercial Name | Chipset |
| :--- | :--- | :--- |
| `nabu` | Xiaomi Pad 5 | Snapdragon 860 |
| `elish` | Xiaomi Pad 5 Pro (Wi-Fi) | Snapdragon 870 |
| `enuma` | Xiaomi Pad 5 Pro 5G | Snapdragon 870 |
| `dagu` | Xiaomi Pad 5 Pro 12.4 | Snapdragon 870 |
| `pipa` | Xiaomi Pad 6 | Snapdragon 870 |
| `liuqin` | Xiaomi Pad 6 Pro | Snapdragon 8+ Gen 1 |
| `yudi` | Xiaomi Pad 6 Max 14 | Snapdragon 8+ Gen 1 |

---

## 📦 Installation

1. Download `magisk-xiaomi-keyboard-fix.zip` from the [Releases](https://github.com/xoxye/xiaomi-pad-keyboard-fix/releases) section.
2. Open **Magisk**, **KernelSU**, or **APatch** app.
3. Select **Modules** ➔ **Install from storage**.
4. Choose the downloaded zip file and flash.
5. Reboot your device.

---

## 🛠️ CLI Diagnostics & Control (`kb`)

After installing the module, the `kb` utility is available via root terminal (`su`):

```bash
su -c kb status
```

### Command Reference:

| Command | Description |
| :--- | :--- |
| `kb status` | Full hardware diagnostics, pogo-pin state, USB bus presence, and daemon PID |
| `kb test` | Live 15-second hardware connection monitor displaying pin states and display mode |
| `kb bind` | Force software re-bind of keyboard USB interfaces |
| `kb reset` | Full power cycle pulse and interface re-enumeration |
| `kb notify` | Test haptic vibration pulse and system notification banner |
| `kb on` | Enable keyboard driver |
| `kb off` | Manually unbind keyboard driver (forces on-screen keyboard) |
| `kb ime_on` | Force show on-screen keyboard even when physical keyboard is connected |
| `kb ime_off` | Hide on-screen keyboard when physical keyboard is connected |

---

## ⚙️ How It Works

1. **Early Boot (`post-fs-data.sh`):**
   Powers the pogo-pin hardware bus via kernel platform driver `soc:xiaomi_keyboard` and configures `power/control` on internal USB keyboard port (dynamically resolved by Vendor ID `3206`) before Android userspace starts.
2. **Post-Unlock Initialization (`service.sh`):**
   Waits until `sys.boot_completed=1` (device storage decrypted), then issues a microsecond power pulse to the keyboard MCU and cleanly registers USB-HID interfaces into Android `EventHub`. A 10-second immunity window protects against post-boot bus transients.
3. **Monolithic Hotplug Loop:**
   Continuously observes `/sys/.../xiaomi_keyboard_conn_status` with debounced edge detection. When detached, it safely unbinds `usbhid` so Android destroys the virtual input devices, allowing the IME to pop up. When attached, it binds interfaces instantly.

---

## 📄 License

Licensed under the [MIT License](LICENSE).

Copyright (c) 2026 **xoxye**.

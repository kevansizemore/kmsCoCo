# kmsCoCo

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#platform-support)
[![Architecture](https://img.shields.io/badge/Arch-ARM64%20%7C%20x86__64-orange.svg)](#building-from-source)

**kmsCoCo** is a streamlined, modernized emulator dedicated specifically to the **Tandy Color Computer (CoCo 1)**. Forked from [XRoar](https://www.6809.org.uk/xroar/), `kmsCoCo` brings a native, refined user experience to modern systems—especially Apple Silicon macOS—while preserving authentic 6809 CPU, SAM, and VDG hardware emulation.

---

## Key Features & Enhancements

* **Native Apple Silicon (ARM64) macOS Integration**:
  * Runs natively with full Cocoa menubar, file dialogs, and CoreAudio integration.
  * Packaged as a self-contained `.app` bundle with bundled frameworks and ad-hoc code signing.
* **Modern Keyboard Mapping (Locked On)**:
  * Host keyboard translation is permanently active—keycaps for `@`, `:`, `"`, `*`, `+`, and `=` always produce the expected character on modern layouts.
  * **CoCo Ergonomics**:
    * **Case Toggle**: Host `Caps Lock` triggers the CoCo's native `Shift + 0` chord to toggle upper/lower case.
    * **Break**: Mapped directly to `Escape`.
    * **Clear**: Mapped to `F12` and `Home`.
    * **Backspace**: Modern `Backspace` / `Delete` maps to CoCo Left arrow.
* **Streamlined Cartridge & Storage UI**:
  * Relocated **Cartridge** menu under **File** with one-click **"Run cartridge ROM…"** (loads `.rom` or `.ccc` files and instantly boots/resets).
  * Direct access to RS-DOS disk controller cartridge, Games, and blank cartridges.
  * Floppy disk drives (1–4) with write-enable and flush management.
* **Interactive Cassette Tape Deck**:
  * Native macOS tape control window with transport controls, counter, non-destructive file segment boundary detection, and optional real-time audio monitor ("screaming robots").
* **Virtual Printer**:
  * Emulates CoCo serial/parallel printer output directly to text files or shell pipes.
* **Multi-Platform**:
  * Clean Autotools build system supporting macOS, Windows (MinGW-w64), and Linux (SDL2 / GTK3 / ALSA / PulseAudio).

---

## Keyboard Reference

| Function | CoCo Native Equivalent | Host Keyboard Key |
| :--- | :--- | :--- |
| **Break** | `BREAK` | <kbd>Escape</kbd> |
| **Clear** | `CLEAR` | <kbd>F12</kbd> or <kbd>Home</kbd> |
| **Backspace** | `←` (Left) | <kbd>Backspace</kbd> / <kbd>Delete</kbd> |
| **Case Toggle** | `SHIFT` + `0` | <kbd>Caps Lock</kbd> or <kbd>Shift</kbd>+<kbd>0</kbd> |
| **Symbols** | `@`, `:`, `"`, `*`, `+`, `=` | Matches modern keyboard layout |
| **Joystick 1** | Right Joystick | Mapped USB Gamepad or Numpad |

---

## System ROMs & Legal Notice

> [!IMPORTANT]
> **kmsCoCo does not include or distribute proprietary Tandy / RadioShack ROM images.**
> Users must supply legally dumped ROMs from their own hardware.

Place ROM files in your user configuration directory:
* **macOS**: `~/Library/kmsCoCo/roms/`
* **Linux**: `~/.kmscoco/roms/`
* **Windows**: `%USERPROFILE%\.kmscoco\roms\`

Standard filenames recognized by the emulator include:
* `bas12.rom` or `bas13.rom` (Color BASIC 1.2 / 1.3)
* `extbas10.rom` or `extbas11.rom` (Extended Color BASIC 1.0 / 1.1)
* `disk11.rom` (RS-DOS Disk Controller ROM)

---

## Quick Start (Pre-Built Releases)

Download the latest pre-compiled build for your platform from the [GitHub Releases](https://github.com/kevansizemore/kmsCoCo/releases) page:
* **macOS**: Download `kmsCoCo-macos-arm64.dmg` (or `.tar.gz`), drag `kmsCoCo.app` to `/Applications`.
* **Windows**: Download `kmsCoCo-windows-x64.zip`, extract, and launch `kmscoco.exe`.
* **Linux**: Download `kmsCoCo-linux-x86_64.tar.gz`, extract, and run `./kmscoco`.

---

## Community & Forking (No Issues / PRs)

This repository operates strictly on a **Fork-First** model:
* **Issues, Bug Reports, and Discussions are permanently disabled by design.**
* **Pull requests are not monitored, reviewed, or accepted.**
* **Forks are warmly welcomed!** Under the terms of the [GNU GPLv3](LICENSE), you are encouraged to fork this repository, apply your own fixes, build enhancements, and maintain your own version. Please review [CONTRIBUTING.md](CONTRIBUTING.md) for complete details.

---

## Building from Source

### Prerequisites
* **macOS**:
  ```bash
  brew install autoconf automake pkg-config sdl2 libpng
  ```
* **Ubuntu / Debian Linux**:
  ```bash
  sudo apt-get update
  sudo apt-get install build-essential autoconf automake pkg-config \
                       libsdl2-dev libpng-dev libasound2-dev libpulse-dev
  ```

### Build Instructions
```bash
# 1. Bootstrap build system
./autogen.sh

# 2. Configure (macOS Apple Silicon example)
./configure --enable-ui-sdl --with-cocoa --with-coreaudio --with-sdl2 \
            CFLAGS="-O3 -arch arm64" LDFLAGS="-arch arm64"

# 3. Compile
make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)

# 4. (macOS only) Bundle into standalone .app
./tools/package-macos-app.sh
```

---

## Acknowledgements & Lineage

`kmsCoCo` is a customized fork of **XRoar**, created and authored by **Ciaran Anscomb**.

* **Original Project**: [XRoar: Dragon & Tandy 8-bit Computer Emulator](https://www.6809.org.uk/xroar/)
* **Upstream Author**: Ciaran Anscomb (<xroar@6809.org.uk>)
* **License**: GNU General Public License v3.0 or later ([LICENSE](LICENSE))

We extend our sincere thanks to Ciaran Anscomb and the 6809 / Color Computer preservation community for decades of diligent research, reverse engineering, and open-source contribution.

Portions of this fork's architecture, documentation, and modernization were developed with the assistance of Google Gemini and Antigravity.

---

## Disclaimer & Terms of Use

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS, MAINTAINERS, OR CONTRIBUTORS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

USE OF THIS REPOSITORY, CODEBASE, OR ASSOCIATED BINARIES CONSTITUTES ACCEPTANCE OF THESE TERMS. FOR DETAILS ON CONTRIBUTIONS AND PROJECT STATUS, PLEASE REVIEW [CONTRIBUTING.md](CONTRIBUTING.md).

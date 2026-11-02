# kmsCoCo Apple Silicon (ARM64) Port Status & Fork Identity

## Summary
**kmsCoCo** is a customized fork of XRoar/XRoARM targeting modern Apple Silicon macOS (ARM64) and Tandy Color Computer / Dragon emulation.

## Identity & Branding
- **Package Name**: `kmsCoCo` (`PACKAGE_TARNAME: kmscoco`)
- **Primary Binary**: `src/kmscoco` (with backwards-compatible `xroar` symlink)
- **Application Bundle**: `kmsCoCo.app` (`/Applications/kmsCoCo.app`)
- **Bundle Identifier**: `com.kms.kmscoco`
- **Application Class**: `kmsCoCoApplication` (Cocoa NSApplication subclass)
- **Target Machine**: Exclusively **Tandy CoCo (PAL)** (`coco`)
- **Storage & Media (File Menu)**:
  - **Cartridge**: Relocated from Hardware to File menu; includes **`Run cartridge ROM…`** (loads `.rom`/`.ccc` image and immediately boots/resets), `None` (eject), `RS-DOS` (disk controller pak), and displays any active ROM cartridge with a radio indicator
  - **Floppy Disks**: Drive 1-4 (Insert, New, Write enable, Write back, Eject)
  - **Cassette Tapes**: Input tape, Output tape, Rewind, Play, Fast loading, CAS padding
  - (HD0/HD1 block devices removed from UI)
- **Keyboard Layout & Translation**:
  - Exclusively **Tandy CoCo**
  - **Keyboard translation (`kbd-translate`) permanently enabled & locked ON**: UI toggle removed; host keyboard symbols (`@`, `:`, `"`, `*`, `+`, `=`) always match their modern keycaps
  - **Break**: `Escape` key (preempts unicode translation)
  - **Clear**: `F12` key and `Home` key
  - **Left / Backspace**: `Backspace` and `Delete` keys
  - **Caps Lock / Case Toggle**: Modern `Caps Lock` key (automatically triggers the CoCo's native `Shift + 0` chord) as well as vintage `Shift + 0`
  - **Arrow Keys**: Directional keys (Up, Down, Left, Right)
  - **Keyboard Guide**: Accessible via menubar `Help -> kmsCoCo Keyboard Guide...` or `Tool -> kmsCoCo Keyboard Guide...`, with inline shortcut references in the `Help` menu
- **Virtual Printer**: Enabled (Print to file, Print to pipe, Flush buffer)
- **Multi-Platform Support**: Cross-compilation scripts, MinGW (Windows 10/11), and Linux (GTK / SDL / ALSA / PulseAudio) autotools pipelines preserved
- **Configuration Search Paths**:
  - macOS: `~/Library/kmsCoCo`
  - Linux: `~/.kmscoco`
  - Config file: `kmscoco.conf`
  - Env vars: `KMSCOCO_CONF_PATH`
- **Packaging Tool**: `tools/package-macos-app.sh`

## Completed Milestones
1. **Dependencies Installed (Homebrew)**:
   - `autoconf` (2.73)
   - `automake` (1.19)
   - `pkg-config` (3.0.10)
   - `sdl2-compat` (2.32.74, providing `sdl2-config` and SDL2 API mapped to SDL3)
   - `libpng` (1.6.x)
2. **Build Configuration Bootstrapped**:
   - `autoreconf -fi` generated clean modern Autotools scripts for Darwin.
   - Configured with:
     ```bash
     PATH="/opt/homebrew/bin:$PATH" ./configure \
       --enable-ui-sdl \
       --with-cocoa \
       --with-coreaudio \
       --with-sdl2 \
       --without-sdl3 \
       --without-x \
       --without-gtk3 \
       --without-gtk2 \
       CFLAGS="-O3 -arch arm64" \
       OBJCFLAGS="-O3 -arch arm64" \
       LDFLAGS="-arch arm64"
     ```
   - Features detected and enabled:
     - Target host: `aarch64-apple-darwin27.2.0`
     - UI: Cocoa (`ui_macosx.m`) + SDL2 (`ui_sdl2.c`, `vo_sdl2.c`, `vo_opengl.c`)
     - Audio: Native macOS CoreAudio (`ao_macosx.c`)
     - Keyboard: Native Darwin HIToolbox / TIS Unicode translation (`hkbd_darwin.c`)
     - Screenshot/Graphics: `libpng`, `zlib`
3. **Compilation**:
   - `make -j$(sysctl -n hw.ncpu)` compiles all source modules and links `src/kmscoco`.
   - Symlink `src/xroar -> kmscoco` created automatically.
   - Built Mach-O 64-bit executable arm64.
4. **Standalone `kmsCoCo.app` Bundle Packaged**:
   - Built via `tools/package-macos-app.sh`.
   - Bundle structure with `Contents/MacOS`, `Contents/Resources`, `Contents/Frameworks`.
   - Modernized `Info.plist` with `NSHighResolutionCapable` for Retina display scaling.
   - Relocated Homebrew dylibs (`libSDL2-2.0.0.dylib`, `libpng16.16.dylib`) into `Contents/Frameworks/`.
   - Bundled `libSDL3.0.dylib` / `libSDL3.dylib` into `Contents/Frameworks/`: Homebrew's `sdl2-compat` dynamically loads `libSDL3.dylib` at runtime via `@loader_path/libSDL3.dylib`.
   - Updated install IDs and dependency paths with `install_name_tool` to `@executable_path/../Frameworks/` and `@loader_path/libSDL3.dylib` for full portability without Homebrew dependencies.
   - Verified that all dynamic library references are self-contained.
5. **Code Signing & Application Installation**:
   - Signed all bundled frameworks and `kmsCoCo.app` with ad-hoc signature (`codesign --force --deep --sign - kmsCoCo.app`).
   - Verified strict designated requirement satisfaction (`codesign --verify --deep --strict --verbose=2 kmsCoCo.app`).
   - Packaged and installed **`kmsCoCo.app`** to `/Applications/kmsCoCo.app`.

## Launch Instructions
Launch the installed application from Spotlight, Launchpad, Finder, or terminal:
```bash
open /Applications/kmsCoCo.app
```
Or execute the command-line binary directly:
```bash
./src/kmscoco
```

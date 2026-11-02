# kmsCoCo Architecture & Developer Manual

> **For Future Human & Agentic Maintainers**: This document provides a comprehensive technical overview of the kmsCoCo codebase. It values clarity over cleverness and assumes no prior familiarity with the emulator's internal subsystems.

---

## 1. System Overview & Architecture

kmsCoCo is an accurate, cycle-stepped emulator for the Motorola 6809/Hitachi 6309 microcomputer family, focusing primarily on the **Tandy Color Computer 1, 2, and 3**, the **Dragon 32/64**, and the **Tandy MC-10**.

### Core Architecture Diagram

```
+-------------------------------------------------------------------------+
|                              Host Platform                              |
|          macOS Cocoa (AppKit) / SDL2 / SDL3 / POSIX / CoreAudio         |
+-------------------------------------------------------------------------+
       |                         |                             |
       v                         v                             v
+------------------+   +-------------------+       +-----------------------+
|  User Interface  |   |  Audio Output     |       |   Video Output (VO)   |
|  (ui_macosx.m)   |   |  (ao.c / sound.c) |       |  (vo_render / vo.c)   |
+------------------+   +-------------------+       +-----------------------+
       |                                                       ^
       |              +-------------------------+              |
       +------------> |   Central Event Loop    | -------------+
                      |   (events.c / xroar.c)  |
                      +-------------------------+
                                   |
         +-------------------------+-------------------------+
         |                         |                         |
         v                         v                         v
+------------------+      +------------------+      +------------------+
|   CPU Core       |      |   Memory & ROM   |      |  I/O & Support   |
| (MC6809 / HD6309)|      |  (SAM 6883 /     |      |  PIA 6821        |
|  m6809.c / cpu.c |      |   GIME / MMU)    |      |  VDG 6847 (MC6847|
+------------------+      +------------------+      +------------------+
         |                         |                         |
         +-------------------------+-------------------------+
                                   |
          +------------------------+------------------------+
          |                        |                        |
          v                        v                        v
+--------------------+   +--------------------+   +--------------------+
| Retro Tape Deck    |   | Virtual Disk (VD)  |   | Auto-Keyboard (AK) |
| (tape_deck.c /     |   | (vdisk.c /         |   | (auto_kbd.c /      |
|  tape_cas.c)       |   |  vdrive.c)         |   |  ROM vectors)      |
+--------------------+   +--------------------+   +--------------------+
```

---

## 2. Directory Structure & Key Files

| Directory / File | Description |
|---|---|
| `src/xroar.c`, `src/xroar.h` | Top-level coordinator, lifecycle control, configuration loader, and command dispatch. |
| `src/machine.c`, `src/machine.h` | Machine definition records, hardware reset routines, interface binding, and peripheral registration. |
| `src/events.c`, `src/events.h` | Microsecond / cycle-based event scheduler for timed asynchronous hardware notifications. |
| `src/tape_deck.c`, `src/tape_deck.h` | Retro Cassette Deck state machine, CAS block parser, physical file byte slicer, and audio monitor. |
| `src/macosx/tape_deck_cocoa.m` | AppKit Cocoa UI for the Retro Cassette Deck (speaker grille, piano keys, index table). |
| `src/macosx/ui_macosx.m` | macOS AppKit menubar, Preferences controller, file open/save dialogs, and native application delegates. |
| `src/vdisk.c`, `src/vdisk.h` | Virtual floppy disk controller supporting `.dsk`, `.dmk`, `.vdk`, and `.jvc` image formats. |
| `src/tape.c`, `src/tape_cas.c` | Low-level cassette bit-stream decoders, FSK pulse generators, and CUE marker structures. |
| `src/auto_kbd.c`, `src/auto_kbd.h` | Automated text-injection subsystem hooked through Color BASIC's `POLCAT` keyboard vector. |
| `src/printer.c`, `src/printer.h` | Tandy Line Printer VII / DMP-100 serial bit-banger emulation and virtual PDF rendering. |
| `src/sound.c`, `src/sound.h` | Multi-channel audio mixer uniting 6-bit DAC sound, cassette audio streaming, and AY-3-8910 audio. |

---

## 3. Subsystem Deep Dives

### 3.1. Retro Cassette Deck Subsystem

The cassette subsystem provides authentic 1500-baud FSK audio simulation coupled with non-destructive binary file manipulation.

#### CAS Boundary Parsing & Physical Splicing
* In `.cas` files, recordings begin with leader bytes (`$55`) preceding a Header block (`$3C $00 $0F ...`) and terminate after an End-of-File block (`$3C $FF $00 $FF`).
* In [src/tape_deck.c](../src/tape_deck.c), `tape_deck_scan_file_boundaries()` scans the raw binary blocks of the `.cas` file and stores exact physical file spans (`file_offset` and `file_len`) in `struct tape_deck_segment`.
* **Overwrite vs. Insert vs. Delete**:
  * **Overwrite**: When slot $i$ is overwritten, bytes `[0, file_offset)` are copied as Part 1, the newly recorded program is spliced as Part 2, and `[file_offset + file_len, data_end)` is preserved as Part 3.
  * **Delete**: Splices `[0, file_offset)` and `[file_offset + file_len, data_end)`, cleanly removing the targeted segment without corrupting surrounding files.

#### Real-Time Audio Streaming ("Screaming Robots")
* When `audio_monitor` is active, the pulse-in routine in `tape_cas.c` translates tape pulses into real-time audio samples fed into `sound_cas_pulse()`.
* When **Authentic Speed** is engaged, loading runs at authentic 1500 baud, allowing users to listen to the FSK audio stream during `CLOAD`.
* When **Turbo Speed** is engaged, `fast_speed` sets `ui_tag_tape_flag_fast`, bypassing real-time delays. The sound button is disabled in this mode.

---

### 3.2. Floppy Disk Emulation & Image Formats

#### .DSK vs. .DMK Architectural Differences

```
.DSK (Raw Sector Image)
+---------------+---------------+---------------+-----+---------------+
| Trk 0, Sec 1  | Trk 0, Sec 2  | Trk 0, Sec 3  | ... | Trk 34, Sec 18|
|  (256 bytes)  |  (256 bytes)  |  (256 bytes)  |     |  (256 bytes)  |
+---------------+---------------+---------------+-----+---------------+

.DMK (Emulated Track Container)
+---------------+------------------------+--------------------------+
| 16-byte Header| Track 0: 64-entry IDAM | Track 0: Raw Track Flux  |
| (Heads, Cyls, | Pointer Table          | (Sync marks, Gaps, IDAMs,|
| Track Length) | (128 bytes)            |  Sector Bodies, CRCs)    |
+---------------+------------------------+--------------------------+
```

* **`.DSK` (Raw Sector Image)**:
  * Linear array of 256-byte sector payloads with no gaps, no sync bytes, and no CRC checksums.
  * A standard 35-track single-sided CoCo disk is exactly $35 \times 18 \times 256 = 161,280$ bytes.
  * **CoCoSDC Compatibility**: The CoCoSDC microcontroller firmware mounts FAT files and computes linear logical block addresses (`LBA = track * 18 + sector`). Because it expects raw payloads, it works natively with `.DSK`.
* **`.DMK` (David M. Keil Container)**:
  * Emulates low-level disk track flux. Each track contains a 128-byte IDAM table (64 16-bit pointers pointing to sector address marks `$FE` and density flags) followed by raw track data (sync marks `$A1`, `$C2`, inter-sector gaps `$4E`, `$FF`, data address marks `$FB`, and CRC polynomials).
  * **Why CoCoSDC Rejects `.DMK`**: The CoCoSDC does not implement a software FM/MFM flux decoder to translate IDAM tables and track gap bytes on the fly.
  * **CoCo3_MiSTer Compatibility**: CoCo3_MiSTer FPGA implementations generally rely on raw `.DSK` (or `.VDK`) sector images mounted via the MiSTer Linux ARM controller.

#### Automatic RS-DOS Formatting (`vdisk_format_rsdos`)
When creating a new disk (`File > Drive > New disk…`), kmsCoCo provides an automatic formatting checkbox:
* Calls `vdisk_format_rsdos(disk)`:
  * Formats 35 cylinders, 1 head, 18 sectors/track (256 bytes/sector, double density).
  * Writes `$00` data bytes to all user data tracks (0..16, 18..34).
  * Writes RS-DOS Directory & FAT structure on Track 17:
    * Sector 2 (FAT): 68 free granules (`$FF`).
    * Sectors 3..11 (Directory): 72 available directory slots (`$FF`).
  * Immediately saves and flushes the formatted image to host storage.
  * The disk is immediately usable (`DIR`, `SAVE`, `OPEN`) without running `DSKINI0`.

---

### 3.3. Text Injection & Auto-Keyboard (`auto_kbd.c`)

* **Keyboard Scan Vectoring**: Color BASIC evaluates keyboard input by checking the `POLCAT` ROM routine (`$A1CB` in Color BASIC 1.2, `$A1C1` in Color BASIC 1.0).
* **Breakpoint Architecture**:
  * `auto_kbd` attaches a breakpoint to `POLCAT`. When triggered, it injects the next queued ASCII byte into CPU register `A`, clears the zero flag (`Z = 0`), and executes an immediate `RTS`.
  * **Timing Preservation**: Breakpoints must never hook `delay_1ms` during standard pasting, as doing so permanently breaks Color BASIC internal timer loops.
  * **Watchdog / Cancellation**: Any machine reset calls `auto_kbd_cancel()` to ensure all breakpoints are uninstalled if a user halts or resets while text is typing.

---

## 4. Maintenance & Contribution Rules

When modifying or extending kmsCoCo, adhere to the following principles:

1. **Maintain Timing Integrity**: Never hook internal CPU timing loops (`delay_1ms`) unless explicitly running a temporary batch conversion that cleans up after itself.
2. **Preserve Native Platform Standards**:
   * On macOS, pass `NSAttributedString` to AppKit about panels and always set explicit `target` references on `NSMenuItem` where responder-chain ambiguity could arise.
   * Expand tildes (`~`) and test directory validity before invoking `setDirectoryURL:` on `NSOpenPanel`/`NSSavePanel`.
3. **Persist Recent Media**: Any media insertion action (`tape_deck_insert_file`, `xroar_insert_disk_file`, `xroar_load_file_by_type`) must call `recent_media_add(type, path)` to ensure state persists across user sessions.
4. **Clarity Over Cleverness**: Code must be readable by any C99 / Objective-C developer without obscure macros or undocumented bitwise side-effects.

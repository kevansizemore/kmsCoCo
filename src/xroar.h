/* XRoar initialisation and top-level emulator functions.
 *
 * Copyright 2003-2025 Ciaran Anscomb
 *
 * This file is part of XRoar, a Dragon/Tandy CoCo emulator.
 *
 * XRoar is free software; you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version.
 *
 * See COPYING.GPL for redistribution conditions.
 */

#ifndef XROAR_XROAR_H_
#define XROAR_XROAR_H_

#include "top-config.h"

#include <stdint.h>
#include <stdio.h>

#include "ui.h"
#include "xconfig.h"

struct ao_interface;
struct cart;
struct event_list;
struct machine_config;
struct slist;
struct vdg_palette;
struct vdrive_interface;
struct vo_interface;
struct xroar_timeout;

// Convenient values for arguments to helper functions
#define XROAR_PREV  (-3)
#define XROAR_NEXT  (-2)  // cycle or toggle setting
#define XROAR_AUTO  (-1)  // default, possible based on other settings
#define XROAR_OFF    (0)
#define XROAR_ON     (1)

enum xroar_filetype {
	FILETYPE_UNKNOWN,

	// Disk types
	FILETYPE_VDK,  // Often used for Dragon disks
	FILETYPE_JVC,  // Basic, with optional headers
	FILETYPE_OS9,  // JVC, but inspected to reveal OS9 metadata
	FILETYPE_DMK,  // David Keil's format records more information

	// Binary types
	FILETYPE_BIN,  // Generic ".bin", needs analysing for subtype
	FILETYPE_HEX,  // Intel HEX format
	FILETYPE_S19,  // Motorola S19 format

	// Cassette types
	FILETYPE_CAS,  // Simple bit format with optional CUE data
	FILETYPE_ASC,  // ASCII text, converted on-the-fly to CAS
	FILETYPE_K7,   // Logical blocks with header metadata
	FILETYPE_WAV,  // Audio sample

	// ROM images
	FILETYPE_ROM,  // Binary dump with optional header ("DGN")

	// Snapshots
	FILETYPE_SNA,  // Machine state dump, V1 or V2
	FILETYPE_RAM,  // Simple RAM dump (write only!)

	// HD images
	FILETYPE_VHD,  // 256 byte-per-sector image
	FILETYPE_IDE,  // 512 byte-per-sector image with header
	FILETYPE_IMG,  // Generic, heuristic decides if it's VHD or IDE
};

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

// Command line arguments

struct xroar_cfg {

	// Audio
	struct {
		char *device;
		int format;
		int rate;
		int channels;
		int fragments;
		int fragment_ms;
		int fragment_nframes;
		int buffer_ms;
		int buffer_nframes;
	} ao;

	// Keyboard
	struct {
		struct slist *bind_list;
	} kbd;

	// Becker port
	struct {
		bool prefer;
		char *ip;
		char *port;
	} becker;

	// Files
	struct {
		char *rompath;
		char *cart_path;
		char *disk_path;
		char *tape_path;
	} file;

	// Cassettes
	struct {
		double pan;
		double hysteresis;
		int rewrite_gap_ms;
		int rewrite_leader;
		int ao_rate;
	} tape;

	// Disks
	struct {
		bool write_back;
		bool auto_os9;
		bool auto_sd;
	} disk;

	// XXX this might make more sense as a per-machine option
	bool force_crc_match;

	// Debugging
	struct {
		bool gdb;
		char *gdb_ip;
		char *gdb_port;
		bool gdb_pseudo_regs;
		bool gdb_flags_as_struct;
	} debug;
};

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

// Global emulator state

struct xroar {
	struct xroar_cfg cfg;

	struct event_list *ui_events;
	struct event_list *machine_events;

	struct ui_interface *ui_interface;
	struct vo_interface *vo_interface;
	struct ao_interface *ao_interface;

	struct machine_config *machine_config;
	struct machine *machine;
	struct auto_kbd *auto_kbd;

	struct keyboard_interface *keyboard_interface;
	struct tape_interface *tape_interface;
	struct printer_interface *printer_interface;
	struct vdrive_interface *vdrive_interface;

	int msgr_client_id;

	struct {
		struct {
			int picture;
			bool frameskip;
		} vo;

		bool ratelimit_latch;
	} state;
};

extern struct xroar xroar;

#define UI_EVENT_LIST xroar.ui_events
#define MACHINE_EVENT_LIST xroar.machine_events

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

// Configure XRoar, initialise modules and start machine.
struct ui_interface *xroar_init(int argc, char **argv);

// Finish initialisation (sets first machine options, attaches media).
void xroar_init_finish(void);

// Cleanly shut down before program exit.
void xroar_shutdown(void);

#ifdef AUTOSAVE_PREFIX
// Save configuration to known location.
void xroar_save_config_file(void);
#endif

// Process UI event queue and run emulated machine.
void xroar_run(int ncycles);

int xroar_filetype_by_ext(const char *filename);
void xroar_load_file_by_type(const char *filename, int autorun);
void xroar_load_disk(const char *filename, int drive, bool autorun);

// Helper functions
void xroar_set_trace(int mode, unsigned n);
void xroar_new_disk(int drive);
#ifdef HAVE_COCOA
bool cocoa_filereq_last_disk_auto_format(void);
#else
static inline bool cocoa_filereq_last_disk_auto_format(void) { return false; }
#endif
void xroar_insert_disk_file(int drive, const char *filename);
void xroar_insert_disk(int drive);
void xroar_eject_disk(int drive);
void xroar_insert_hd_file(int drive, const char *filename);
void xroar_set_ratelimit(int action);
void xroar_set_ratelimit_latch(bool notify, int action);
void xroar_set_pause(bool notify, int action);
#define xroar_quit() exit(EXIT_SUCCESS)
void xroar_load_file(void);
void xroar_run_file(void);
void xroar_flush_printer(void);
void xroar_connect_machine(void);
void xroar_configure_machine(struct machine_config *mc);
void xroar_update_cartridge_menu(void);
void xroar_save_snapshot(void);
void xroar_insert_input_tape_file(const char *filename);
void xroar_insert_input_tape(void);
void xroar_eject_input_tape(void);
void xroar_insert_output_tape_file(const char *filename);
void xroar_insert_output_tape(void);
void xroar_eject_output_tape(void);
void xroar_hard_reset(void);
void xroar_soft_reset(void);
void xroar_screenshot(void);

// Helper functions for config printing
void xroar_cfg_print_inc_indent(void);
void xroar_cfg_print_dec_indent(void);
void xroar_cfg_print_indent(FILE *f);
void xroar_cfg_print_bool(FILE *f, bool all, char const *opt, int value, int normal);
void xroar_cfg_print_int(FILE *f, bool all, char const *opt, int value, int normal);
void xroar_cfg_print_int_nz(FILE *f, bool all, char const *opt, int value);
void xroar_cfg_print_double(FILE *f, bool all, char const *opt, double value, double normal);
void xroar_cfg_print_flags(FILE *f, bool all, char const *opt, unsigned value);
void xroar_cfg_print_string(FILE *f, bool all, char const *opt, char const *value,
			    char const *normal);
void xroar_cfg_print_enum(FILE *f, bool all, char const *opt, int value, int normal,
			  struct xconfig_enum const *e);
void xroar_cfg_print_string_list(FILE *f, bool all, char const *opt, struct slist *l);

enum recent_media_type {
	RECENT_MEDIA_CART = 0,
	RECENT_MEDIA_DISK = 1,
	RECENT_MEDIA_TAPE = 2,
};

struct recent_entry {
	char *path;
	enum recent_media_type type;
};

#define MAX_RECENT_MEDIA 10
extern struct recent_entry recent_media_list[MAX_RECENT_MEDIA];
extern int num_recent_media;

void recent_media_add(enum recent_media_type type, const char *path);
void recent_media_clear(void);

struct coco_rom_status {
	bool has_bas;
	bool has_extbas;
	bool has_rsdos;
	bool all_ok;
	char *bas_path;
	char *extbas_path;
	char *rsdos_path;
};

void check_coco_roms(struct coco_rom_status *status);
void free_coco_rom_status(struct coco_rom_status *status);

const char *xroar_get_cart_path(void);
const char *xroar_get_disk_path(void);
const char *xroar_get_tape_path(void);
const char *xroar_get_rom_path(void);

void xroar_set_cart_path(const char *path);
void xroar_set_disk_path(const char *path);
void xroar_set_tape_path(const char *path);
void xroar_set_rom_path(const char *path);

enum printer_dest {
	PRINTER_DEST_NONE = 0,
	PRINTER_DEST_PROMPT = 1,
	PRINTER_DEST_PDF = 2,
	PRINTER_DEST_TEXT = 3,
	PRINTER_DEST_FILE = 4,
	PRINTER_DEST_PIPE = 5,
};

enum printer_font_family {
	PRINTER_FONT_MONO = 0,
	PRINTER_FONT_SERIF = 1,
	PRINTER_FONT_SANS = 2,
};

const char *xroar_get_print_path(void);
void xroar_set_print_path(const char *path);

int xroar_get_print_dest(void);
void xroar_set_print_dest(int dest);

int xroar_get_print_font_family(void);
void xroar_set_print_font_family(int family);

float xroar_get_print_font_size(void);
void xroar_set_print_font_size(float size);

float xroar_get_print_margin(void);
void xroar_set_print_margin(float margin);

int xroar_get_print_autoflush_ms(void);
void xroar_set_print_autoflush_ms(int ms);

enum printer_page_num_loc {
	PRINTER_PAGE_NUM_NONE = 0,
	PRINTER_PAGE_NUM_BOTTOM_CENTER = 1,
	PRINTER_PAGE_NUM_BOTTOM_RIGHT = 2,
	PRINTER_PAGE_NUM_BOTTOM_LEFT = 3,
	PRINTER_PAGE_NUM_TOP_CENTER = 4,
	PRINTER_PAGE_NUM_TOP_RIGHT = 5,
	PRINTER_PAGE_NUM_TOP_LEFT = 6,
};

enum printer_page_num_fmt {
	PRINTER_PAGE_NUM_FMT_PAGE_N_OF_TOTAL = 0,
	PRINTER_PAGE_NUM_FMT_PAGE_N = 1,
	PRINTER_PAGE_NUM_FMT_N_OF_TOTAL = 2,
	PRINTER_PAGE_NUM_FMT_N = 3,
};

const char *xroar_get_print_header_title(void);
void xroar_set_print_header_title(const char *title);

bool xroar_get_print_header_show_title(void);
void xroar_set_print_header_show_title(bool show);

bool xroar_get_print_header_show_date(void);
void xroar_set_print_header_show_date(bool show);

int xroar_get_print_page_num_loc(void);
void xroar_set_print_page_num_loc(int loc);

int xroar_get_print_page_num_fmt(void);
void xroar_set_print_page_num_fmt(int fmt);

#endif

/* kmsCoCo Retro-Analog Tape Deck Controller
 *
 * Copyright 2026 kmsCoCo contributors
 * License: GNU GPL version 3 or later
 */

#ifndef KMSCOCO_TAPE_DECK_H_
#define KMSCOCO_TAPE_DECK_H_

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#define TAPE_DECK_MAX_SEGMENTS 24

enum tape_capacity_type {
	TAPE_CAPACITY_C15 = 0, // 15 min, 6 slots
	TAPE_CAPACITY_C30 = 1, // 30 min, 12 slots
	TAPE_CAPACITY_C60 = 2, // 60 min, 20 slots
};

struct tape_deck_segment {
	int index;
	char name[16];
	int type;             // 0: BASIC, 1: DATA, 2: ML (Binary)
	bool ascii_flag;
	int start_address;
	int load_address;
	long offset;          // tape seek offset (samples)
	long file_offset;     // physical file byte start offset
	long file_len;        // physical file byte length
	long size_bytes;
	int start_ms;
	int end_ms;
};

struct tape_deck_status {
	char filename[1024];
	char display_title[128];
	bool has_tape;
	bool is_playing;
	bool is_recording;
	bool motor_on;
	bool audio_monitor;
	bool fast_speed;
	int capacity_type;
	int max_slots;
	int current_index;     // 0-based index or -1
	int num_segments;
	int counter;
	int current_ms;
	int total_ms;
	struct tape_deck_segment segments[TAPE_DECK_MAX_SEGMENTS];
};

void tape_deck_init(void);
void tape_deck_free(void);

// Cassette insertion & ejection
bool tape_deck_insert_file(const char *path);
void tape_deck_eject(void);
bool tape_deck_create_new(const char *path, int capacity_type);
void tape_deck_refresh_index(void);

// Transport buttons (CTR-66 Piano Keys)
void tape_deck_play(void);
bool tape_deck_record(void);
bool tape_deck_record_mode(bool overwrite);
bool tape_deck_delete_segment(int index);
void tape_deck_stop(void);
void tape_deck_rewind_step(void);
void tape_deck_ffwd_step(void);
void tape_deck_seek_index(int index);
void tape_deck_rewind_start(void);

// Audio Monitor ("Screaming Robots" Speaker) & Speed Control
void tape_deck_set_audio_monitor(bool enable);
bool tape_deck_get_audio_monitor(void);
void tape_deck_set_fast_speed(bool fast);
bool tape_deck_get_fast_speed(void);

// Mechanical Tape Counter
void tape_deck_reset_counter(void);
int tape_deck_get_counter(void);

// Hardware motor relay state callback
void tape_deck_notify_motor(bool motor_on);

// Status
void tape_deck_get_status(struct tape_deck_status *status);

#endif

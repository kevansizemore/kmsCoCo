/* kmsCoCo Retro-Analog Tape Deck Controller
 *
 * Copyright 2026 kmsCoCo contributors
 * License: GNU GPL version 3 or later
 */

#include "top-config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include "xalloc.h"
#include "logging.h"
#include "sound.h"
#include "machine.h"
#include "tape.h"
#include "ui.h"
#include "xroar.h"
#include "events.h"
#include "tape_deck.h"

struct tape_deck_data {
	char filename[1024];
	char display_title[128];
	char temp_rec_filename[1024];
	bool has_tape;
	bool is_playing;
	bool is_recording;
	bool record_is_overwrite;
	int record_target_index;
	bool motor_on;
	bool audio_monitor;
	bool fast_speed;
	int capacity_type;
	int max_slots;
	int current_index;
	int num_segments;
	int counter_zero_ms;
	struct event record_finish_event;
	struct tape_deck_segment segments[TAPE_DECK_MAX_SEGMENTS];
};

static struct tape_deck_data deck;

static void tape_deck_scan(void);
static void tape_deck_finalize_record(void);
static long tape_deck_get_data_end(const char *filename);
static void tape_deck_scan_file_boundaries(void);

static void on_record_finish(void *sptr) {
	(void)sptr;
	tape_deck_finalize_record();
}

void tape_deck_init(void) {
	memset(&deck, 0, sizeof(deck));
	deck.capacity_type = TAPE_CAPACITY_C15;
	deck.max_slots = 6;
	deck.current_index = -1;
	deck.audio_monitor = false;
	deck.fast_speed = false;
	event_init(&deck.record_finish_event, MACHINE_EVENT_LIST, DELEGATE_AS0(void, on_record_finish, NULL));
}

void tape_deck_free(void) {
	if (deck.record_finish_event.queued) {
		event_dequeue(&deck.record_finish_event);
	}
	if (deck.temp_rec_filename[0]) {
		unlink(deck.temp_rec_filename);
		deck.temp_rec_filename[0] = '\0';
	}
}

static long tape_deck_get_data_end(const char *filename) {
	FILE *f = fopen(filename, "rb");
	if (!f) return 0;
	fseek(f, 0, SEEK_END);
	long fsize = ftell(f);
	long data_end = fsize;

	if (fsize >= 12) {
		fseek(f, fsize - 4, SEEK_SET);
		uint8_t cue_marker[4];
		if (fread(cue_marker, 1, 4, f) == 4 &&
		    cue_marker[0] == 'C' && cue_marker[1] == 'U' &&
		    cue_marker[2] == 'E' && cue_marker[3] == ']') {
			fseek(f, fsize - 8, SEEK_SET);
			uint8_t cstart[4];
			if (fread(cstart, 1, 4, f) == 4) {
				long cs = ((long)cstart[0] << 24) | ((long)cstart[1] << 16) |
				          ((long)cstart[2] << 8) | (long)cstart[3];
				if (cs >= 0 && cs < fsize - 8) {
					fseek(f, cs, SEEK_SET);
					uint8_t start_marker[4];
					if (fread(start_marker, 1, 4, f) == 4 &&
					    start_marker[0] == '[' && start_marker[1] == 'C' &&
					    start_marker[2] == 'U' && start_marker[3] == 'E') {
						data_end = cs;
					}
				}
			}
		}
	}
	fclose(f);
	return data_end;
}

static void tape_deck_scan_file_boundaries(void) {
	if (deck.num_segments <= 0 || !deck.filename[0]) return;

	long data_end = tape_deck_get_data_end(deck.filename);
	if (data_end <= 0) return;

	FILE *f = fopen(deck.filename, "rb");
	if (!f) return;

	uint8_t *buf = xmalloc(data_end);
	size_t read_bytes = fread(buf, 1, data_end, f);
	fclose(f);

	if (read_bytes < 4) {
		free(buf);
		return;
	}

	int seg_idx = 0;
	long current_seg_start = 0;
	bool inside_seg = false;
	size_t p = 0;

	while (p + 3 < read_bytes) {
		if (buf[p] == 0x3C) {
			uint8_t btype = buf[p + 1];
			uint8_t blen = buf[p + 2];
			size_t block_end = p + 3 + blen + 1; // 0x3C, type, len, blen bytes, checksum
			if (block_end > read_bytes) {
				p++;
				continue;
			}

			if (btype == 0x00 && blen >= 15) {
				// Header block
				if (!inside_seg) {
					inside_seg = true;
				}
				p = block_end;
				continue;
			}

			if (btype == 0xFF) {
				// EOF block
				if (inside_seg && seg_idx < deck.num_segments) {
					long seg_end = (long)block_end;
					deck.segments[seg_idx].file_offset = current_seg_start;
					deck.segments[seg_idx].file_len = seg_end - current_seg_start;
					seg_idx++;
					current_seg_start = seg_end;
					inside_seg = false;
				}
				p = block_end;
				continue;
			}

			p = block_end;
			continue;
		}
		p++;
	}

	if (inside_seg && seg_idx < deck.num_segments) {
		deck.segments[seg_idx].file_offset = current_seg_start;
		deck.segments[seg_idx].file_len = data_end - current_seg_start;
		seg_idx++;
	}

	if (seg_idx > 0) {
		// Include any trailing bytes (up to data_end) in the last segment
		deck.segments[seg_idx - 1].file_len = data_end - deck.segments[seg_idx - 1].file_offset;
	}

	free(buf);
}

static void tape_deck_scan(void) {
	deck.num_segments = 0;
	if (!xroar.tape_interface || !xroar.tape_interface->tape_input) {
		return;
	}

	struct tape *t = xroar.tape_interface->tape_input;
	long orig_offset = tape_tell(t);
	tape_rewind(t);

	struct tape_file *f;
	while ((f = tape_file_next(t, 1)) != NULL) {
		if (deck.num_segments >= TAPE_DECK_MAX_SEGMENTS) {
			free(f);
			break;
		}
		struct tape_deck_segment *seg = &deck.segments[deck.num_segments];
		seg->index = deck.num_segments;
		snprintf(seg->name, sizeof(seg->name), "%s", f->name);
		seg->type = f->type;
		seg->ascii_flag = f->ascii_flag;
		seg->start_address = f->start_address;
		seg->load_address = f->load_address;
		seg->offset = f->offset;
		seg->start_ms = tape_to_ms(t, f->offset);
		seg->end_ms = seg->start_ms;
		seg->size_bytes = 0;

		if (deck.num_segments > 0) {
			deck.segments[deck.num_segments - 1].end_ms = seg->start_ms;
			deck.segments[deck.num_segments - 1].size_bytes = seg->offset - deck.segments[deck.num_segments - 1].offset;
		}

		deck.num_segments++;
		free(f);
	}

	if (deck.num_segments > 0) {
		long total_size = t->size > 0 ? t->size : tape_tell(t);
		int total_ms = tape_to_ms(t, total_size);
		deck.segments[deck.num_segments - 1].end_ms = total_ms > deck.segments[deck.num_segments - 1].start_ms ? total_ms : deck.segments[deck.num_segments - 1].start_ms + 8000;
		deck.segments[deck.num_segments - 1].size_bytes = total_size > deck.segments[deck.num_segments - 1].offset ? (total_size - deck.segments[deck.num_segments - 1].offset) : 1024;
	}

	tape_seek(t, orig_offset, SEEK_SET);

	tape_deck_scan_file_boundaries();
}

bool tape_deck_insert_file(const char *path) {
	if (!path || !*path) return false;
	tape_deck_stop();
	tape_deck_eject();

	snprintf(deck.filename, sizeof(deck.filename), "%s", path);
	const char *base = strrchr(path, '/');
	base = base ? (base + 1) : path;
	snprintf(deck.display_title, sizeof(deck.display_title), "%s", base);

	int open_res = tape_open_reading(xroar.tape_interface, path);
	if (open_res == -1) {
		// Accept 0-byte newly created files
		FILE *f = fopen(path, "rb");
		if (f) {
			fseek(f, 0, SEEK_END);
			long sz = ftell(f);
			fclose(f);
			if (sz == 0) {
				open_res = 0;
			}
		}
	}

	if (open_res == -1) {
		return false;
	}

	deck.has_tape = true;
	deck.is_playing = false;
	deck.is_recording = false;
	deck.current_index = 0;
	deck.counter_zero_ms = 0;

	recent_media_add(RECENT_MEDIA_TAPE, path);
	tape_deck_scan();
	tape_deck_rewind_start();
	return true;
}

void tape_deck_eject(void) {
	tape_deck_stop();
	tape_close_reading(xroar.tape_interface);
	tape_close_writing(xroar.tape_interface);

	deck.has_tape = false;
	deck.filename[0] = '\0';
	deck.display_title[0] = '\0';
	deck.num_segments = 0;
	deck.current_index = -1;
	deck.counter_zero_ms = 0;

	if (deck.temp_rec_filename[0]) {
		unlink(deck.temp_rec_filename);
		deck.temp_rec_filename[0] = '\0';
	}
}

bool tape_deck_create_new(const char *path, int capacity_type) {
	if (!path || !*path) return false;
	FILE *f = fopen(path, "wb");
	if (!f) return false;
	fclose(f);

	deck.capacity_type = capacity_type;
	switch (capacity_type) {
	case TAPE_CAPACITY_C15: deck.max_slots = 6; break;
	case TAPE_CAPACITY_C30: deck.max_slots = 12; break;
	case TAPE_CAPACITY_C60: deck.max_slots = 20; break;
	default: deck.max_slots = 6; break;
	}

	if (!tape_deck_insert_file(path)) {
		return false;
	}

	// Automatic arm for recording on a brand new blank cassette
	tape_deck_record();
	return true;
}

void tape_deck_refresh_index(void) {
	if (deck.has_tape) {
		tape_deck_scan();
	}
}

void tape_deck_play(void) {
	if (!deck.has_tape) return;
	if (deck.is_recording) {
		tape_deck_finalize_record();
	}

	if (!xroar.tape_interface->tape_input) {
		tape_open_reading(xroar.tape_interface, deck.filename);
	}

	deck.is_playing = true;
	deck.is_recording = false;
	ui_update_state(-1, ui_tag_tape_playing, 1, NULL);
}

bool tape_deck_record_mode(bool overwrite) {
	if (!deck.has_tape) return false;
	if (deck.num_segments >= deck.max_slots && !overwrite) {
		LOG_MOD_WARN("tape_deck", "Cassette is full (capacity reached)\n");
		return false;
	}

	// If already recording, stop previous staging session cleanly
	if (deck.is_recording) {
		tape_deck_stop();
	}

	deck.is_recording = true;
	deck.is_playing = true;
	deck.record_is_overwrite = overwrite;
	deck.record_target_index = deck.current_index;

	// Close reading so tape_interface is not simultaneously reading from disk
	tape_close_reading(xroar.tape_interface);

	// Setup clean temporary staging file for writing
	snprintf(deck.temp_rec_filename, sizeof(deck.temp_rec_filename),
	         "/tmp/kmscoco_rec_%d.cas", (int)getpid());
	FILE *f = fopen(deck.temp_rec_filename, "wb");
	if (f) fclose(f);

	tape_open_writing(xroar.tape_interface, deck.temp_rec_filename);
	ui_update_state(-1, ui_tag_tape_playing, 1, NULL);
	return true;
}

bool tape_deck_record(void) {
	return tape_deck_record_mode(false);
}

bool tape_deck_delete_segment(int index) {
	if (!deck.has_tape || index < 0 || index >= deck.num_segments) {
		return false;
	}

	tape_deck_stop();
	tape_close_reading(xroar.tape_interface);
	tape_close_writing(xroar.tape_interface);

	long data_end = tape_deck_get_data_end(deck.filename);
	long seg_start = deck.segments[index].file_offset;
	long seg_end = deck.segments[index].file_offset + deck.segments[index].file_len;
	if (seg_start > data_end) seg_start = data_end;
	if (seg_end > data_end) seg_end = data_end;

	size_t part1_len = (size_t)seg_start;
	size_t part2_len = (seg_end < data_end) ? (size_t)(data_end - seg_end) : 0;

	uint8_t *part1 = NULL;
	uint8_t *part2 = NULL;

	FILE *f = fopen(deck.filename, "rb");
	if (f) {
		if (part1_len > 0) {
			part1 = xmalloc(part1_len);
			fseek(f, 0, SEEK_SET);
			fread(part1, 1, part1_len, f);
		}
		if (part2_len > 0) {
			part2 = xmalloc(part2_len);
			fseek(f, seg_end, SEEK_SET);
			fread(part2, 1, part2_len, f);
		}
		fclose(f);
	}

	f = fopen(deck.filename, "wb");
	if (f) {
		if (part1 && part1_len > 0) {
			fwrite(part1, 1, part1_len, f);
		}
		if (part2 && part2_len > 0) {
			fwrite(part2, 1, part2_len, f);
		}
		fclose(f);
	}

	if (part1) free(part1);
	if (part2) free(part2);

	tape_open_reading(xroar.tape_interface, deck.filename);
	tape_deck_scan();

	if (deck.num_segments == 0) {
		deck.current_index = 0;
	} else if (index < deck.num_segments) {
		deck.current_index = index;
	} else {
		deck.current_index = deck.num_segments - 1;
	}
	tape_deck_seek_index(deck.current_index);
	return true;
}

static void tape_deck_finalize_record(void) {
	if (!deck.is_recording) return;
	if (deck.record_finish_event.queued) {
		event_dequeue(&deck.record_finish_event);
	}
	deck.is_recording = false;
	deck.is_playing = false;

	// Close writing on temporary file so all blocks and CUE footer are flushed
	tape_close_writing(xroar.tape_interface);

	long rec_data_end = tape_deck_get_data_end(deck.temp_rec_filename);
	if (rec_data_end <= 0) {
		// Nothing recorded (e.g. cancelled or no audio produced)
		if (deck.temp_rec_filename[0]) {
			unlink(deck.temp_rec_filename);
			deck.temp_rec_filename[0] = '\0';
		}
		tape_open_reading(xroar.tape_interface, deck.filename);
		tape_deck_scan();
		ui_update_state(-1, ui_tag_tape_playing, 0, NULL);
		return;
	}

	// Read new recording's CAS data from temp staging file
	uint8_t *rec_data = xmalloc(rec_data_end);
	FILE *rf = fopen(deck.temp_rec_filename, "rb");
	if (rf) {
		fread(rec_data, 1, rec_data_end, rf);
		fclose(rf);
	}
	unlink(deck.temp_rec_filename);
	deck.temp_rec_filename[0] = '\0';

	// Splicing: extract untouched slices from deck.filename
	long orig_data_end = tape_deck_get_data_end(deck.filename);
	int target = deck.record_target_index;
	bool overwrite = deck.record_is_overwrite;

	long part1_end = 0;
	long part3_start = orig_data_end;

	if (target >= 0 && target < deck.num_segments) {
		part1_end = deck.segments[target].file_offset;
		if (overwrite) {
			part3_start = deck.segments[target].file_offset + deck.segments[target].file_len;
		} else {
			// Insert / Shift Down
			part3_start = deck.segments[target].file_offset;
		}
	} else {
		// Append at end of existing recordings
		part1_end = orig_data_end;
		part3_start = orig_data_end;
	}

	if (part1_end > orig_data_end) part1_end = orig_data_end;
	if (part3_start > orig_data_end) part3_start = orig_data_end;
	if (part3_start < part1_end) part3_start = part1_end;

	size_t part1_len = (size_t)part1_end;
	size_t part3_len = (part3_start < orig_data_end) ? (size_t)(orig_data_end - part3_start) : 0;

	uint8_t *part1 = NULL;
	uint8_t *part3 = NULL;

	if (orig_data_end > 0) {
		FILE *of = fopen(deck.filename, "rb");
		if (of) {
			if (part1_len > 0) {
				part1 = xmalloc(part1_len);
				fseek(of, 0, SEEK_SET);
				fread(part1, 1, part1_len, of);
			}
			if (part3_len > 0) {
				part3 = xmalloc(part3_len);
				fseek(of, part3_start, SEEK_SET);
				fread(part3, 1, part3_len, of);
			}
			fclose(of);
		}
	}

	// Write spliced contents to original file
	FILE *wf = fopen(deck.filename, "wb");
	if (wf) {
		if (part1 && part1_len > 0) {
			fwrite(part1, 1, part1_len, wf);
		}
		if (rec_data && rec_data_end > 0) {
			fwrite(rec_data, 1, rec_data_end, wf);
		}
		if (part3 && part3_len > 0) {
			fwrite(part3, 1, part3_len, wf);
		}
		fclose(wf);
	}

	if (part1) free(part1);
	if (rec_data) free(rec_data);
	if (part3) free(part3);

	// Re-open original tape for reading and rescan
	tape_open_reading(xroar.tape_interface, deck.filename);
	tape_deck_scan();

	// Set current_index to the recorded segment
	if (target >= 0 && target < deck.num_segments) {
		deck.current_index = target;
	} else if (deck.num_segments > 0) {
		deck.current_index = deck.num_segments - 1;
	} else {
		deck.current_index = 0;
	}
	tape_deck_seek_index(deck.current_index);

	ui_update_state(-1, ui_tag_tape_playing, 0, NULL);
}

void tape_deck_stop(void) {
	if (deck.record_finish_event.queued) {
		event_dequeue(&deck.record_finish_event);
	}
	if (deck.is_recording) {
		deck.is_recording = false;
		deck.is_playing = false;
		tape_close_writing(xroar.tape_interface);
		if (deck.temp_rec_filename[0]) {
			unlink(deck.temp_rec_filename);
			deck.temp_rec_filename[0] = '\0';
		}
		if (!xroar.tape_interface->tape_input) {
			tape_open_reading(xroar.tape_interface, deck.filename);
		}
		tape_deck_scan();
	}
	deck.is_playing = false;
	deck.is_recording = false;
	ui_update_state(-1, ui_tag_tape_playing, 0, NULL);
}

void tape_deck_rewind_step(void) {
	if (!deck.has_tape) return;
	if (deck.num_segments == 0) {
		tape_deck_rewind_start();
		return;
	}

	if (deck.current_index > 0) {
		deck.current_index--;
		tape_deck_seek_index(deck.current_index);
	} else {
		tape_deck_rewind_start();
	}
}

void tape_deck_ffwd_step(void) {
	if (!deck.has_tape) return;
	if (deck.num_segments == 0) return;

	if (deck.current_index < deck.num_segments - 1) {
		deck.current_index++;
		tape_deck_seek_index(deck.current_index);
	} else if (deck.current_index == deck.num_segments - 1) {
		// Seek to the end of the last segment (ready to append)
		struct tape *t = xroar.tape_interface->tape_input;
		if (t) {
			tape_seek(t, t->size, SEEK_SET);
			deck.current_index = deck.num_segments; // at end
		}
	}
}

void tape_deck_seek_index(int index) {
	if (!deck.has_tape || !xroar.tape_interface || !xroar.tape_interface->tape_input) {
		return;
	}
	if (index >= 0 && index < deck.num_segments) {
		struct tape *t = xroar.tape_interface->tape_input;
		tape_seek(t, deck.segments[index].offset, SEEK_SET);
		deck.current_index = index;
	} else if (index == deck.num_segments) {
		struct tape *t = xroar.tape_interface->tape_input;
		tape_seek(t, t->size, SEEK_SET);
		deck.current_index = deck.num_segments;
	}
}

void tape_deck_rewind_start(void) {
	if (!deck.has_tape || !xroar.tape_interface || !xroar.tape_interface->tape_input) {
		return;
	}
	tape_rewind(xroar.tape_interface->tape_input);
	deck.current_index = deck.num_segments > 0 ? 0 : -1;
}

void tape_deck_set_audio_monitor(bool enable) {
	deck.audio_monitor = enable;
	if (xroar.machine && xroar.machine->get_interface) {
		struct sound_interface *snd = xroar.machine->get_interface(xroar.machine, "sound");
		if (snd) {
			sound_set_tape_monitor(snd, enable);
		}
	}

	// When audio monitor is turned ON, default to authentic 1500-baud physical speed
	// unless fast_speed is explicitly enabled
	if (enable) {
		ui_update_state(-1, ui_tag_tape_flag_fast, deck.fast_speed ? 1 : 0, NULL);
	} else {
		// When monitor is OFF, run turbo fast by default
		ui_update_state(-1, ui_tag_tape_flag_fast, 1, NULL);
	}
}

bool tape_deck_get_audio_monitor(void) {
	return deck.audio_monitor;
}

void tape_deck_set_fast_speed(bool fast) {
	deck.fast_speed = fast;
	ui_update_state(-1, ui_tag_tape_flag_fast, fast ? 1 : 0, NULL);
}

bool tape_deck_get_fast_speed(void) {
	return deck.fast_speed;
}

void tape_deck_reset_counter(void) {
	if (deck.has_tape && xroar.tape_interface && xroar.tape_interface->tape_input) {
		long off = tape_tell(xroar.tape_interface->tape_input);
		deck.counter_zero_ms = tape_to_ms(xroar.tape_interface->tape_input, off);
	} else {
		deck.counter_zero_ms = 0;
	}
}

int tape_deck_get_counter(void) {
	if (!deck.has_tape || !xroar.tape_interface || !xroar.tape_interface->tape_input) {
		return 0;
	}
	long off = tape_tell(xroar.tape_interface->tape_input);
	int cur_ms = tape_to_ms(xroar.tape_interface->tape_input, off);
	int delta = cur_ms - deck.counter_zero_ms;
	if (delta < 0) delta = 0;
	// ~1.5s per mechanical counter tick
	return delta / 1500;
}

void tape_deck_notify_motor(bool motor_on) {
	bool prev = deck.motor_on;
	deck.motor_on = motor_on;

	if (deck.is_recording) {
		if (motor_on) {
			// Motor turned on: cancel any pending finalize event (e.g. between block 0 and block 1)
			if (deck.record_finish_event.queued) {
				event_dequeue(&deck.record_finish_event);
			}
		} else if (prev) {
			// Motor turned off: queue finalize after 1.5s of sustained motor inactivity
			event_queue_dt(&deck.record_finish_event, EVENT_MS(1500));
		}
	}
}

void tape_deck_get_status(struct tape_deck_status *status) {
	if (!status) return;
	memset(status, 0, sizeof(*status));

	snprintf(status->filename, sizeof(status->filename), "%s", deck.filename);
	snprintf(status->display_title, sizeof(status->display_title), "%s", deck.display_title);
	status->has_tape = deck.has_tape;
	status->is_playing = deck.is_playing;
	status->is_recording = deck.is_recording;
	status->motor_on = deck.motor_on;
	status->audio_monitor = deck.audio_monitor;
	status->fast_speed = deck.fast_speed;
	status->capacity_type = deck.capacity_type;
	status->max_slots = deck.max_slots;
	status->current_index = deck.is_recording ? deck.record_target_index : deck.current_index;
	status->num_segments = deck.num_segments;
	status->counter = tape_deck_get_counter();

	if (deck.has_tape && xroar.tape_interface && xroar.tape_interface->tape_input) {
		struct tape *t = xroar.tape_interface->tape_input;
		long off = tape_tell(t);
		status->current_ms = tape_to_ms(t, off);
		status->total_ms = tape_to_ms(t, t->size > 0 ? t->size : off);
	}

	for (int i = 0; i < deck.num_segments && i < TAPE_DECK_MAX_SEGMENTS; i++) {
		status->segments[i] = deck.segments[i];
	}
}

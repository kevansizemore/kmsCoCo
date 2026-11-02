/* Printing to file or pipe
 *
 * Copyright 2011-2026 Ciaran Anscomb
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

#include "top-config.h"

// for popen, pclose
#define _POSIX_C_SOURCE 200112L

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sds.h"
#include "xalloc.h"

#include "delegate.h"
#include "events.h"
#include "logging.h"
#include "part.h"
#include "path.h"
#include "printer.h"
#include "ui.h"
#include "xroar.h"

struct printer_interface_private {
	struct printer_interface public;

	// Messenger client id
	int msgr_client_id;

	int destination;
	sds filename;  // for PRINTER_DESTINATION_FILE
	sds pipe;      // for PRINTER_DESTINATION_PIPE

	FILE *stream;
	struct event ack_clear_event;
	bool strobe_state;
	bool busy;

	int chars_printed;
	struct event update_chars_printed_event;

	sds buffer;
	int autoflush_ms;
	struct event autoflush_event;
};

static void printer_ui_set_print_destination(void *, int tag, void *smsg);
static void printer_ui_set_print_file(void *, int tag, void *smsg);
static void printer_ui_set_print_pipe(void *, int tag, void *smsg);

static void open_stream(struct printer_interface_private *pip);
static void close_stream(struct printer_interface_private *pip);
static void do_ack_clear(void *);
static void do_update_chars_printed(void *);
static void do_autoflush(void *);

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

struct printer_interface *printer_interface_new(void) {
	struct printer_interface_private *pip = xmalloc(sizeof(*pip));
	*pip = (struct printer_interface_private){0};

	pip->msgr_client_id = messenger_client_register();
	ui_messenger_preempt_group(pip->msgr_client_id, ui_tag_print_destination, MESSENGER_NOTIFY_DELEGATE(printer_ui_set_print_destination, pip));
	ui_messenger_preempt_group(pip->msgr_client_id, ui_tag_print_file, MESSENGER_NOTIFY_DELEGATE(printer_ui_set_print_file, pip));
	ui_messenger_preempt_group(pip->msgr_client_id, ui_tag_print_pipe, MESSENGER_NOTIFY_DELEGATE(printer_ui_set_print_pipe, pip));

	pip->destination = PRINTER_DESTINATION_NONE;
	pip->filename = NULL;
	pip->pipe = NULL;
	pip->stream = NULL;
	event_init(&pip->ack_clear_event, MACHINE_EVENT_LIST, DELEGATE_AS0(void, do_ack_clear, pip));
	event_init(&pip->update_chars_printed_event, UI_EVENT_LIST, DELEGATE_AS0(void, do_update_chars_printed, pip));
	pip->buffer = sdsempty();
	pip->autoflush_ms = 2000;
	event_init(&pip->autoflush_event, UI_EVENT_LIST, DELEGATE_AS0(void, do_autoflush, pip));
	pip->strobe_state = 1;
	pip->busy = 0;
	return &pip->public;
}

void printer_interface_free(struct printer_interface *pi) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	messenger_client_unregister(pip->msgr_client_id);
	close_stream(pip);
	if (pip->filename)
		sdsfree(pip->filename);
	if (pip->pipe)
		sdsfree(pip->pipe);
	event_dequeue(&pip->ack_clear_event);
	event_dequeue(&pip->update_chars_printed_event);
	event_dequeue(&pip->autoflush_event);
	if (pip->buffer)
		sdsfree(pip->buffer);
	free(pip);
}

void printer_set_autoflush_ms(struct printer_interface *pi, int ms) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	pip->autoflush_ms = ms;
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

void printer_reset(struct printer_interface *pi) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	pip->strobe_state = 1;
}

static void printer_ui_set_print_destination(void *sptr, int tag, void *smsg) {
	struct printer_interface_private *pip = sptr;
	struct ui_state_message *uimsg = smsg;
	assert(tag == ui_tag_print_destination);

	int dest = uimsg->value;
	if (dest < PRINTER_DESTINATION_NONE || dest > PRINTER_DESTINATION_PIPE) {
		dest = PRINTER_DESTINATION_NONE;
	}
	if (dest != pip->destination) {
		printer_flush(&pip->public);
		pip->destination = dest;
		if (dest == PRINTER_DESTINATION_FILE && !pip->filename) {
			pip->busy = 1;
		} else if (dest == PRINTER_DESTINATION_PIPE && !pip->pipe) {
			pip->busy = 1;
		} else {
			pip->busy = 0;
		}
	}
	uimsg->value = dest;
}

static void printer_ui_set_print_file(void *sptr, int tag, void *smsg) {
	struct printer_interface_private *pip = sptr;
	struct ui_state_message *uimsg = smsg;
	assert(tag == ui_tag_print_file);

	const char *filename = uimsg->data;
	if (pip->destination == PRINTER_DESTINATION_FILE) {
		close_stream(pip);
	}
	if (pip->filename) {
		sdsfree(pip->filename);
		pip->filename = NULL;
	}
	if (filename) {
		pip->filename = path_interp(filename);
	}
	if (pip->destination == PRINTER_DESTINATION_FILE) {
		pip->busy = 0;
	}
}

static void printer_ui_set_print_pipe(void *sptr, int tag, void *smsg) {
	struct printer_interface_private *pip = sptr;
	struct ui_state_message *uimsg = smsg;
	assert(tag == ui_tag_print_pipe);

	const char *pipe = uimsg->data;
	if (pip->destination == PRINTER_DESTINATION_PIPE) {
		close_stream(pip);
	}
	if (pip->pipe) {
		sdsfree(pip->pipe);
		pip->pipe = NULL;
	}
	if (pipe) {
		pip->pipe = sdsnew(pipe);
	}
	if (pip->destination == PRINTER_DESTINATION_PIPE) {
		pip->busy = 0;
	}
}

/* close stream but leave stream_dest intact so it will be reopened */
void printer_flush(struct printer_interface *pi) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	event_dequeue(&pip->autoflush_event);

	if (pip->stream) {
		if (pip->destination == PRINTER_DESTINATION_PIPE) {
#ifdef HAVE_POPEN
			pclose(pip->stream);
#endif
		}
		if (pip->destination == PRINTER_DESTINATION_FILE) {
			fclose(pip->stream);
		}
		pip->stream = NULL;
	}

	if (pip->buffer && sdslen(pip->buffer) > 0) {
		sds clean = sdsempty();
		size_t blen = sdslen(pip->buffer);
		for (size_t i = 0; i < blen; i++) {
			unsigned char c = (unsigned char)pip->buffer[i];
			if (c == '\r') {
				clean = sdscatlen(clean, "\n", 1);
				if (i + 1 < blen && pip->buffer[i + 1] == '\n') {
					i++;
				}
			} else if (c == '\n' || c == '\t' || c == '\f') {
				clean = sdscatlen(clean, (char *)&c, 1);
			} else if (c >= 0x20 && c <= 0x7E) {
				clean = sdscatlen(clean, (char *)&c, 1);
			} else if (c >= 0x80) {
				unsigned char ascii_c = c & 0x7F;
				if (ascii_c >= 0x20 && ascii_c <= 0x7E) {
					clean = sdscatlen(clean, (char *)&ascii_c, 1);
				} else {
					clean = sdscatlen(clean, " ", 1);
				}
			}
		}

		if (sdslen(clean) > 0) {
			DELEGATE_SAFE_CALL(pi->print_job_completed, clean, sdslen(clean));
		}
		sdsfree(clean);
		sdssetlen(pip->buffer, 0);
	}

	pip->chars_printed = 0;
	if (!event_queued(&pip->update_chars_printed_event)) {
		event_queue_dt(&pip->update_chars_printed_event, EVENT_MS(500));
	}
}

// Called when the PIA bus containing STROBE is changed

void printer_strobe(struct printer_interface *pi, bool strobe, int data) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	// Ignore if this is not a transition to high
	if (strobe == pip->strobe_state) return;
	pip->strobe_state = strobe;
	if (!pip->strobe_state) return;

	if (pip->destination == PRINTER_DESTINATION_NONE) {
		// ACK and return
		DELEGATE_SAFE_CALL(pi->signal_ack, 1);
		event_queue_dt(&pip->ack_clear_event, EVENT_US(7));
		return;
	}

	if (!pip->buffer) {
		pip->buffer = sdsempty();
	}
	char ch = (char)data;
	pip->buffer = sdscatlen(pip->buffer, &ch, 1);

	// Open stream for output if it's not already (for legacy file/pipe)
	if (!pip->stream && (pip->destination == PRINTER_DESTINATION_FILE || pip->destination == PRINTER_DESTINATION_PIPE))
		open_stream(pip);
	// Print byte
	if (pip->stream) {
		fputc(data, pip->stream);
	}

	// Schedule UI notify
	pip->chars_printed++;
	if (!event_queued(&pip->update_chars_printed_event)) {
		event_queue_dt(&pip->update_chars_printed_event, EVENT_MS(500));
	}

	// Reset autoflush timer
	if (pip->autoflush_ms > 0) {
		event_dequeue(&pip->autoflush_event);
		event_queue_dt(&pip->autoflush_event, EVENT_MS(pip->autoflush_ms));
	}

	// ACK, and schedule !ACK
	DELEGATE_SAFE_CALL(pi->signal_ack, 1);
	event_queue_dt(&pip->ack_clear_event, EVENT_US(7));
}

static void do_autoflush(void *sptr) {
	struct printer_interface_private *pip = sptr;
	printer_flush(&pip->public);
}

bool printer_busy(struct printer_interface *pi) {
	struct printer_interface_private *pip = (struct printer_interface_private *)pi;
	return pip->busy;
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

static void open_stream(struct printer_interface_private *pip) {
	if (pip->destination == PRINTER_DESTINATION_PIPE && pip->pipe) {
#ifdef HAVE_POPEN
		pip->stream = popen(pip->pipe, "w");
#endif
	} else if (pip->destination == PRINTER_DESTINATION_FILE && pip->filename) {
		pip->stream = fopen(pip->filename, "ab");
	}
	if (pip->stream) {
		pip->busy = 0;
	}
}

static void close_stream(struct printer_interface_private *pip) {
	printer_flush(&pip->public);
	pip->busy = 1;
}

static void do_ack_clear(void *sptr) {
	struct printer_interface_private *pip = sptr;
	struct printer_interface *pi = &pip->public;
	DELEGATE_SAFE_CALL(pi->signal_ack, 0);
}

static void do_update_chars_printed(void *sptr) {
	struct printer_interface_private *pip = sptr;
	ui_update_state(-1, ui_tag_print_count, pip->chars_printed, NULL);
}

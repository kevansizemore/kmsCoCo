/* Printing to file or pipe
 *
 * Copyright 2011-2024 Ciaran Anscomb
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

#ifndef XROAR_PRINTER_H_
#define XROAR_PRINTER_H_

#include "delegate.h"

enum {
	PRINTER_DESTINATION_NONE = 0,
	PRINTER_DESTINATION_PROMPT = 1,
	PRINTER_DESTINATION_PDF = 2,
	PRINTER_DESTINATION_TEXT = 3,
	PRINTER_DESTINATION_FILE = 4,
	PRINTER_DESTINATION_PIPE = 5,
};

struct printer_interface {
	DELEGATE_T1(void, bool) signal_ack;
	DELEGATE_T2(void, charcp, size_t) print_job_completed;
};

struct printer_interface *printer_interface_new(void);
void printer_interface_free(struct printer_interface *pi);
void printer_reset(struct printer_interface *pi);

void printer_flush(struct printer_interface *pi);
void printer_strobe(struct printer_interface *pi, bool strobe, int data);
bool printer_busy(struct printer_interface *pi);
void printer_set_autoflush_ms(struct printer_interface *pi, int ms);

#endif

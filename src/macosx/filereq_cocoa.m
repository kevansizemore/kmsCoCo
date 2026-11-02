/* Cocoa file requester module for Mac OS X.
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

#import <Cocoa/Cocoa.h>

#include "delegate.h"
#include "xalloc.h"

#include "module.h"
#include "ui.h"
#include "xroar.h"

static void *filereq_cocoa_new(void *cfg);

struct module filereq_cocoa_module = {
	.name = "cocoa", .description = "Cocoa file requester",
	.new = filereq_cocoa_new
};

extern int cocoa_super_all_keys;

struct cocoa_filereq_interface {
	struct filereq_interface public;
};

static void filereq_cocoa_free(void *sptr);
static char *load_filename(void *sptr, char const *title);
static char *save_filename(void *sptr, char const *title);

static void *filereq_cocoa_new(void *cfg) {
	(void)cfg;
	struct cocoa_filereq_interface *frcocoa = xmalloc(sizeof(*frcocoa));
	*frcocoa = (struct cocoa_filereq_interface){0};
	frcocoa->public.free = DELEGATE_AS0(void, filereq_cocoa_free, frcocoa);
	frcocoa->public.load_filename = DELEGATE_AS1(charp, charcp, load_filename, frcocoa);
	frcocoa->public.save_filename = DELEGATE_AS1(charp, charcp, save_filename, frcocoa);
	return frcocoa;
}

static void filereq_cocoa_free(void *sptr) {
	struct cocoa_filereq_interface *frcocoa = sptr;
	free(frcocoa);
}

/* Assuming filenames are UTF8 strings seems to do the job */

static char *load_filename(void *sptr, char const *title) {
	struct cocoa_filereq_interface *frcocoa = sptr;
	NSWindow *keyWindow = [[NSApplication sharedApplication] keyWindow];
	NSOpenPanel *dialog = [NSOpenPanel openPanel];
	NSString *ntitle = [[NSString alloc] initWithUTF8String:title];
	[dialog setTitle:ntitle];

	const char *hint = NULL;
	if (strcasestr(title, "cartridge") || strcasestr(title, "cart")) {
		hint = xroar_get_cart_path();
	} else if (strcasestr(title, "disk") || strcasestr(title, "floppy")) {
		hint = xroar_get_disk_path();
	} else if (strcasestr(title, "tape")) {
		hint = xroar_get_tape_path();
	}
	if (hint && *hint) {
		NSString *hp = [[NSString stringWithUTF8String:hint] stringByExpandingTildeInPath];
		BOOL isDir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:hp isDirectory:&isDir] && isDir) {
			[dialog setDirectoryURL:[NSURL fileURLWithPath:hp isDirectory:YES]];
		}
	}

	cocoa_super_all_keys = 1;
	char *filename = NULL;
	if ([dialog runModal] == NSModalResponseOK) {
		filename = xstrdup([[[[dialog URLs] objectAtIndex:0] path] UTF8String]);
	}
	cocoa_super_all_keys = 0;
	[ntitle release];
	[keyWindow makeKeyAndOrderFront:nil];
	return filename;
}

static bool cocoa_last_disk_auto_format = true;

bool cocoa_filereq_last_disk_auto_format(void) {
	return cocoa_last_disk_auto_format;
}

static char *save_filename(void *sptr, char const *title) {
	struct cocoa_filereq_interface *frcocoa = sptr;
	NSWindow *keyWindow = [[NSApplication sharedApplication] keyWindow];
	NSSavePanel *dialog = [NSSavePanel savePanel];
	NSString *ntitle = [[NSString alloc] initWithUTF8String:title];
	[dialog setTitle:ntitle];

	const char *hint = NULL;
	bool is_disk = false;
	if (strcasestr(title, "cartridge") || strcasestr(title, "cart")) {
		hint = xroar_get_cart_path();
	} else if (strcasestr(title, "disk") || strcasestr(title, "floppy")) {
		hint = xroar_get_disk_path();
		is_disk = true;
	} else if (strcasestr(title, "tape")) {
		hint = xroar_get_tape_path();
	}
	if (hint && *hint) {
		NSString *hp = [[NSString stringWithUTF8String:hint] stringByExpandingTildeInPath];
		BOOL isDir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:hp isDirectory:&isDir] && isDir) {
			[dialog setDirectoryURL:[NSURL fileURLWithPath:hp isDirectory:YES]];
		}
	}

	NSButton *autoFormatBtn = nil;
	if (is_disk) {
		[dialog setNameFieldStringValue:@"NewDisk.dsk"];
		[dialog setAllowedFileTypes:@[@"dsk", @"dmk", @"vdk", @"jvc"]];

		NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 36)];
		autoFormatBtn = [[NSButton alloc] initWithFrame:NSMakeRect(14, 6, 460, 24)];
		[autoFormatBtn setButtonType:NSButtonTypeSwitch];
		[autoFormatBtn setTitle:@"Automatically format disk for immediate use (Color BASIC / RS-DOS)"];
		[autoFormatBtn setFont:[NSFont systemFontOfSize:12]];
		[autoFormatBtn setState:NSControlStateValueOn]; // Checked by default
		[acc addSubview:autoFormatBtn];
		[dialog setAccessoryView:acc];
		[autoFormatBtn release];
		[acc release];
	}

	cocoa_super_all_keys = 1;
	char *filename = NULL;
	if ([dialog runModal] == NSModalResponseOK) {
		filename = xstrdup([[[dialog URL] path] UTF8String]);
		if (is_disk && autoFormatBtn) {
			cocoa_last_disk_auto_format = ([autoFormatBtn state] == NSControlStateValueOn);
		}
	}
	cocoa_super_all_keys = 0;
	[ntitle release];
	[keyWindow makeKeyAndOrderFront:nil];
	return filename;
}

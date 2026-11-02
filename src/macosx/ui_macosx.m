/* Mac OS X+ user-interface module.
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

/*  Based on SDLMain.m - main entry point for our Cocoa-ized SDL app
 *
 *  Initial Version: Darrell Walisser <dwaliss1@purdue.edu>
 *
 *  Non-NIB-Code & other changes: Max Horn <max@quendi.de>
 *
 *  Feel free to customize this file to suit your needs.
 */

#include "top-config.h"

#include <SDL.h>
#include <sys/param.h> /* for MAXPATHLEN */
#include <unistd.h>

#import <Cocoa/Cocoa.h>
//#import <AppKit/AppKit.h>

#include "slist.h"
#include "xalloc.h"

#include "auto_kbd.h"
#include "blockdev.h"
#include "cart.h"
#include "hkbd.h"
#include "joystick.h"
#include "keyboard.h"
#include "logging.h"
#include "machine.h"
#include "messenger.h"
#include "module.h"
#include "printer.h"
#include "tape.h"
#include "ui.h"
#include "vdisk.h"
#include "vo.h"
#include "vo_render.h"
#include "xroar.h"
#include "sdl2/common.h"

#include "macosx/ui_macosx.h"
#include "tape_deck.h"
#import "macosx/tape_deck_cocoa.h"

// Extend the UI tags for our own purposes

enum {
	uimac_tag_joystick_right = ui_num_tags,
	uimac_tag_joystick_left,
	uimac_tag_hd_new,
	uimac_tag_hd_detach,
	uimac_tag_config_save,
};

static const char *hd_type_name[4] = { "20MiB", "40MiB", "128MiB", "256MiB" };
static const int hd_type_map[4] = {
        BD_ACME_NEMESIS,
        BD_ACME_ULTRASONICUS,
        BD_ACME_ACCELLERATTI,
        BD_ACME_ZIPPIBUS
};

@interface SDLMain : NSObject <NSApplicationDelegate>
- (void)orderFrontStandardAboutPanel:(id)sender;
- (void)showTapeDeck:(id)sender;
- (void)insertTapeAction:(id)sender;
- (void)newTapeAction:(id)sender;
- (void)ejectTapeAction:(id)sender;
@end

/* For some reaon, Apple removed setAppleMenu from the headers in 10.4, but the
 * method still is there and works.  To avoid warnings, we declare it ourselves
 * here. */
@interface NSApplication(SDL_Missing_Methods)
- (void)setAppleMenu:(NSMenu *)menu;
@end

static int gArgc;
static char **gArgv;
static BOOL gFinderLaunch;
static BOOL gCalledAppMainline = FALSE;

static NSString *get_application_name(void) {
	const NSDictionary *dict;
	NSString *app_name = 0;

	/* Determine the application name */
	dict = (const NSDictionary *)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
	if (dict)
		app_name = [dict objectForKey: @"CFBundleName"];

	if (![app_name length])
		app_name = [[NSProcessInfo processInfo] processName];

	return app_name;
}

static void cocoa_update_radio_menu_from_enum(NSMenu *menu, struct xconfig_enum *xc_enum,
					      unsigned tag);

/* Setting this to true is a massive hack so that cocoa file dialogues receive
 * keypresses.  Ideally, need to sort SDL out or turn this into a regular
 * OpenGL application.  SDL2 in 2019 note: not sure if this is needed now?  */
int cocoa_super_all_keys = 0;

static NSMenu *recent_menu = nil;
static void cocoa_update_recent_menu(void);

@interface kmsCoCoPreferencesController : NSObject <NSWindowDelegate> {
	NSWindow *prefsWindow;
	NSTextField *romPathField;
	NSTextField *cartPathField;
	NSTextField *diskPathField;
	NSTextField *tapePathField;

	// Printer preferences
	NSPopUpButton *printDestPopup;
	NSPopUpButton *printFamilyPopup;
	NSComboBox *printSizeCombo;
	NSPopUpButton *printMarginPopup;
	NSPopUpButton *printAutoflushPopup;
	NSTextField *printPathField;

	// Header & Page Number preferences
	NSTextField *printHeaderTitleField;
	NSButton *printHeaderShowTitleCheck;
	NSButton *printHeaderShowDateCheck;
	NSPopUpButton *printPageNumLocPopup;
	NSPopUpButton *printPageNumFmtPopup;
}
+ (kmsCoCoPreferencesController *)sharedController;
- (void)showPreferencesWindow;
- (void)browseRom:(id)sender;
- (void)browseCart:(id)sender;
- (void)browseDisk:(id)sender;
- (void)browseTape:(id)sender;
- (void)browsePrint:(id)sender;
- (void)save:(id)sender;
- (void)cancel:(id)sender;
@end

static NSString *get_default_print_dir(void) {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *docsDir = [paths count] > 0 ? [paths objectAtIndex:0] : NSHomeDirectory();
	return [docsDir stringByAppendingPathComponent:@"kmsCoCo/Printouts"];
}

static NSTextField *make_pref_label(NSString *text, NSRect frame) {
	NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
	[label setStringValue:text];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setAlignment:NSTextAlignmentRight];
	[label setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	return label;
}

static NSTextField *make_pref_field(NSRect frame) {
	NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
	[field setBezeled:YES];
	[field setBezelStyle:NSTextFieldSquareBezel];
	[field setDrawsBackground:YES];
	[field setEditable:YES];
	[field setSelectable:YES];
	[field setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	return field;
}

static NSButton *make_pref_button(NSString *title, NSRect frame, id target, SEL action) {
	NSButton *btn = [[NSButton alloc] initWithFrame:frame];
	[btn setTitle:title];
	[btn setButtonType:NSButtonTypeMomentaryPushIn];
	[btn setBezelStyle:NSBezelStyleRounded];
	[btn setTarget:target];
	[btn setAction:action];
	return btn;
}

static NSPopUpButton *make_pref_popup(NSRect frame) {
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
	[popup removeAllItems];
	[popup setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	return popup;
}

static NSComboBox *make_pref_combobox(NSRect frame, NSArray *items) {
	NSComboBox *box = [[NSComboBox alloc] initWithFrame:frame];
	[box setEditable:YES];
	[box setCompletes:YES];
	[box setHasVerticalScroller:YES];
	[box setNumberOfVisibleItems:10];
	[box setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	if (items) {
		[box addItemsWithObjectValues:items];
	}
	return box;
}

static NSButton *make_pref_checkbox(NSString *title, NSRect frame) {
	NSButton *btn = [[NSButton alloc] initWithFrame:frame];
	[btn setButtonType:NSButtonTypeSwitch];
	[btn setTitle:title];
	[btn setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	return btn;
}

@implementation kmsCoCoPreferencesController

+ (kmsCoCoPreferencesController *)sharedController {
	static kmsCoCoPreferencesController *shared = nil;
	if (!shared) {
		shared = [[kmsCoCoPreferencesController alloc] init];
	}
	return shared;
}

- (void)chooseDirectoryForField:(NSTextField *)field title:(NSString *)title {
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setTitle:title];
	[panel setPrompt:@"Select"];
	[panel setCanChooseFiles:NO];
	[panel setCanChooseDirectories:YES];
	[panel setAllowsMultipleSelection:NO];
	NSString *curr = [field stringValue];
	if ([curr length] > 0) {
		NSString *expanded = [curr stringByExpandingTildeInPath];
		BOOL isDir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:expanded isDirectory:&isDir] && isDir) {
			[panel setDirectoryURL:[NSURL fileURLWithPath:expanded isDirectory:YES]];
		}
	}
	cocoa_super_all_keys = 1;
	if ([panel runModal] == NSModalResponseOK) {
		NSURL *url = [[panel URLs] objectAtIndex:0];
		[field setStringValue:[url path]];
	}
	cocoa_super_all_keys = 0;
}

- (void)browseRom:(id)sender {
	(void)sender;
	[self chooseDirectoryForField:romPathField title:@"Select System ROMs Directory"];
}

- (void)browseCart:(id)sender {
	(void)sender;
	[self chooseDirectoryForField:cartPathField title:@"Select Cartridges Directory"];
}

- (void)browseDisk:(id)sender {
	(void)sender;
	[self chooseDirectoryForField:diskPathField title:@"Select Floppy Disks Directory"];
}

- (void)browseTape:(id)sender {
	(void)sender;
	[self chooseDirectoryForField:tapePathField title:@"Select Cassettes Directory"];
}

- (void)browsePrint:(id)sender {
	(void)sender;
	[self chooseDirectoryForField:printPathField title:@"Select Printouts Directory"];
}

- (void)save:(id)sender {
	(void)sender;
	xroar_set_rom_path([[romPathField stringValue] UTF8String]);
	xroar_set_cart_path([[cartPathField stringValue] UTF8String]);
	xroar_set_disk_path([[diskPathField stringValue] UTF8String]);
	xroar_set_tape_path([[tapePathField stringValue] UTF8String]);

	if (printDestPopup) {
		xroar_set_print_dest((int)[printDestPopup selectedTag]);
	}
	if (printFamilyPopup) {
		xroar_set_print_font_family((int)[printFamilyPopup selectedTag]);
	}
	if (printSizeCombo) {
		float fsz = [printSizeCombo floatValue];
		if (fsz < 4.0f || fsz > 144.0f) fsz = 10.0f;
		xroar_set_print_font_size(fsz);
	}
	if (printMarginPopup) {
		float margin = (float)[printMarginPopup selectedTag] / 100.0f;
		xroar_set_print_margin(margin);
	}
	if (printAutoflushPopup) {
		xroar_set_print_autoflush_ms((int)[printAutoflushPopup selectedTag]);
	}
	if (printPathField) {
		xroar_set_print_path([[printPathField stringValue] UTF8String]);
	}
	if (printHeaderTitleField) {
		xroar_set_print_header_title([[printHeaderTitleField stringValue] UTF8String]);
	}
	if (printHeaderShowTitleCheck) {
		xroar_set_print_header_show_title([printHeaderShowTitleCheck state] == NSControlStateValueOn);
	}
	if (printHeaderShowDateCheck) {
		xroar_set_print_header_show_date([printHeaderShowDateCheck state] == NSControlStateValueOn);
	}
	if (printPageNumLocPopup) {
		xroar_set_print_page_num_loc((int)[printPageNumLocPopup selectedTag]);
	}
	if (printPageNumFmtPopup) {
		xroar_set_print_page_num_fmt((int)[printPageNumFmtPopup selectedTag]);
	}

	xroar_save_config_file();
	cocoa_super_all_keys = 0;
	[prefsWindow close];
}

- (void)cancel:(id)sender {
	(void)sender;
	cocoa_super_all_keys = 0;
	[prefsWindow close];
}

- (void)windowWillClose:(NSNotification *)notification {
	(void)notification;
	cocoa_super_all_keys = 0;
}

- (void)showPreferencesWindow {
	if (!prefsWindow) {
		NSRect frame = NSMakeRect(0, 0, 580, 420);
		NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
		prefsWindow = [[NSWindow alloc] initWithContentRect:frame
		                                          styleMask:styleMask
		                                            backing:NSBackingStoreBuffered
		                                              defer:NO];
		[prefsWindow setTitle:@"kmsCoCo Preferences"];
		[prefsWindow setReleasedWhenClosed:NO];
		[prefsWindow setDelegate:self];

		NSView *contentView = [prefsWindow contentView];

		NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(15, 52, 550, 355)];
		[tabView setTabViewType:NSTopTabsBezelBorder];
		[contentView addSubview:tabView];

		// ---- Tab 1: Media Folders ----
		NSTabViewItem *tabFolders = [[NSTabViewItem alloc] initWithIdentifier:@"folders"];
		[tabFolders setLabel:@"Media Folders"];
		NSView *viewFolders = [tabFolders view];

		// System ROMs
		NSTextField *lblRom = make_pref_label(@"System ROMs:", NSMakeRect(10, 212, 120, 20));
		[viewFolders addSubview:lblRom];
		[lblRom release];
		romPathField = make_pref_field(NSMakeRect(135, 210, 280, 24));
		[viewFolders addSubview:romPathField];
		NSButton *btnRom = make_pref_button(@"Browse…", NSMakeRect(425, 206, 85, 30), self, @selector(browseRom:));
		[viewFolders addSubview:btnRom];
		[btnRom release];

		// Cartridges
		NSTextField *lblCart = make_pref_label(@"Cartridges:", NSMakeRect(10, 162, 120, 20));
		[viewFolders addSubview:lblCart];
		[lblCart release];
		cartPathField = make_pref_field(NSMakeRect(135, 160, 280, 24));
		[viewFolders addSubview:cartPathField];
		NSButton *btnCart = make_pref_button(@"Browse…", NSMakeRect(425, 156, 85, 30), self, @selector(browseCart:));
		[viewFolders addSubview:btnCart];
		[btnCart release];

		// Floppy Disks
		NSTextField *lblDisk = make_pref_label(@"Floppy Disks:", NSMakeRect(10, 112, 120, 20));
		[viewFolders addSubview:lblDisk];
		[lblDisk release];
		diskPathField = make_pref_field(NSMakeRect(135, 110, 280, 24));
		[viewFolders addSubview:diskPathField];
		NSButton *btnDisk = make_pref_button(@"Browse…", NSMakeRect(425, 106, 85, 30), self, @selector(browseDisk:));
		[viewFolders addSubview:btnDisk];
		[btnDisk release];

		// Cassettes
		NSTextField *lblTape = make_pref_label(@"Cassettes:", NSMakeRect(10, 62, 120, 20));
		[viewFolders addSubview:lblTape];
		[lblTape release];
		tapePathField = make_pref_field(NSMakeRect(135, 60, 280, 24));
		[viewFolders addSubview:tapePathField];
		NSButton *btnTape = make_pref_button(@"Browse…", NSMakeRect(425, 56, 85, 30), self, @selector(browseTape:));
		[viewFolders addSubview:btnTape];
		[btnTape release];

		[tabView addTabViewItem:tabFolders];
		[tabFolders release];

		// ---- Tab 2: Printer ----
		NSTabViewItem *tabPrinter = [[NSTabViewItem alloc] initWithIdentifier:@"printer"];
		[tabPrinter setLabel:@"Printer"];
		NSView *viewPrinter = [tabPrinter view];

		// Destination
		NSTextField *lblDest = make_pref_label(@"Destination:", NSMakeRect(10, 222, 120, 20));
		[viewPrinter addSubview:lblDest];
		[lblDest release];
		printDestPopup = make_pref_popup(NSMakeRect(135, 219, 280, 26));
		[printDestPopup addItemWithTitle:@"Native Print Dialog / PDF…"];
		[[printDestPopup lastItem] setTag:PRINTER_DEST_PROMPT];
		[printDestPopup addItemWithTitle:@"Auto-Save to PDF"];
		[[printDestPopup lastItem] setTag:PRINTER_DEST_PDF];
		[printDestPopup addItemWithTitle:@"Auto-Save to UTF-8 Text File"];
		[[printDestPopup lastItem] setTag:PRINTER_DEST_TEXT];
		[printDestPopup addItemWithTitle:@"Raw Output to File…"];
		[[printDestPopup lastItem] setTag:PRINTER_DEST_FILE];
		[printDestPopup addItemWithTitle:@"Disabled"];
		[[printDestPopup lastItem] setTag:PRINTER_DEST_NONE];
		[viewPrinter addSubview:printDestPopup];

		// Font Family
		NSTextField *lblFamily = make_pref_label(@"Font Family:", NSMakeRect(10, 182, 120, 20));
		[viewPrinter addSubview:lblFamily];
		[lblFamily release];
		printFamilyPopup = make_pref_popup(NSMakeRect(135, 179, 280, 26));
		[printFamilyPopup addItemWithTitle:@"Monospace (Menlo)"];
		[[printFamilyPopup lastItem] setTag:PRINTER_FONT_MONO];
		[printFamilyPopup addItemWithTitle:@"Serif (Times)"];
		[[printFamilyPopup lastItem] setTag:PRINTER_FONT_SERIF];
		[printFamilyPopup addItemWithTitle:@"Sans-Serif (Helvetica)"];
		[[printFamilyPopup lastItem] setTag:PRINTER_FONT_SANS];
		[viewPrinter addSubview:printFamilyPopup];

		// Font Size (Combo Box)
		NSTextField *lblSize = make_pref_label(@"Font Size:", NSMakeRect(10, 142, 120, 20));
		[viewPrinter addSubview:lblSize];
		[lblSize release];
		NSArray *sizes = @[ @"6", @"7", @"8", @"9", @"10", @"11", @"12", @"13", @"14", @"15",
		                    @"16", @"18", @"20", @"22", @"24", @"28", @"32", @"36", @"48", @"64", @"72" ];
		printSizeCombo = make_pref_combobox(NSMakeRect(135, 140, 80, 24), sizes);
		[viewPrinter addSubview:printSizeCombo];
		NSTextField *lblPt = make_pref_label(@"pt", NSMakeRect(220, 142, 25, 20));
		[lblPt setAlignment:NSTextAlignmentLeft];
		[viewPrinter addSubview:lblPt];
		[lblPt release];

		// Page Margins
		NSTextField *lblMargin = make_pref_label(@"Page Margins:", NSMakeRect(10, 102, 120, 20));
		[viewPrinter addSubview:lblMargin];
		[lblMargin release];
		printMarginPopup = make_pref_popup(NSMakeRect(135, 99, 200, 26));
		[printMarginPopup addItemWithTitle:@"0.25 inch (Narrow)"];
		[[printMarginPopup lastItem] setTag:25];
		[printMarginPopup addItemWithTitle:@"0.50 inch (Normal)"];
		[[printMarginPopup lastItem] setTag:50];
		[printMarginPopup addItemWithTitle:@"0.75 inch"];
		[[printMarginPopup lastItem] setTag:75];
		[printMarginPopup addItemWithTitle:@"1.00 inch (Wide)"];
		[[printMarginPopup lastItem] setTag:100];
		[viewPrinter addSubview:printMarginPopup];

		// Auto-Flush
		NSTextField *lblFlush = make_pref_label(@"Auto-Flush:", NSMakeRect(10, 62, 120, 20));
		[viewPrinter addSubview:lblFlush];
		[lblFlush release];
		printAutoflushPopup = make_pref_popup(NSMakeRect(135, 59, 200, 26));
		[printAutoflushPopup addItemWithTitle:@"1.0 second"];
		[[printAutoflushPopup lastItem] setTag:1000];
		[printAutoflushPopup addItemWithTitle:@"2.0 seconds (Default)"];
		[[printAutoflushPopup lastItem] setTag:2000];
		[printAutoflushPopup addItemWithTitle:@"3.0 seconds"];
		[[printAutoflushPopup lastItem] setTag:3000];
		[printAutoflushPopup addItemWithTitle:@"5.0 seconds"];
		[[printAutoflushPopup lastItem] setTag:5000];
		[printAutoflushPopup addItemWithTitle:@"Manual flush only"];
		[[printAutoflushPopup lastItem] setTag:0];
		[viewPrinter addSubview:printAutoflushPopup];

		// Output Folder
		NSTextField *lblFolder = make_pref_label(@"Output Folder:", NSMakeRect(10, 22, 120, 20));
		[viewPrinter addSubview:lblFolder];
		[lblFolder release];
		printPathField = make_pref_field(NSMakeRect(135, 20, 280, 24));
		[viewPrinter addSubview:printPathField];
		NSButton *btnFolder = make_pref_button(@"Browse…", NSMakeRect(425, 16, 85, 30), self, @selector(browsePrint:));
		[viewPrinter addSubview:btnFolder];
		[btnFolder release];

		[tabView addTabViewItem:tabPrinter];
		[tabPrinter release];

		// ---- Tab 3: Header & Page Numbers ----
		NSTabViewItem *tabHeader = [[NSTabViewItem alloc] initWithIdentifier:@"header"];
		[tabHeader setLabel:@"Header & Pages"];
		NSView *viewHeader = [tabHeader view];

		// Job / File Title
		NSTextField *lblTitle = make_pref_label(@"Job Title:", NSMakeRect(10, 248, 120, 20));
		[viewHeader addSubview:lblTitle];
		[lblTitle release];
		printHeaderTitleField = make_pref_field(NSMakeRect(135, 246, 280, 24));
		[viewHeader addSubview:printHeaderTitleField];

		// Include Title checkbox
		printHeaderShowTitleCheck = make_pref_checkbox(@"Include Job / File Title in Header", NSMakeRect(135, 218, 360, 22));
		[viewHeader addSubview:printHeaderShowTitleCheck];

		// Include Date/Time checkbox
		printHeaderShowDateCheck = make_pref_checkbox(@"Include Date / Timestamp in Header (ISO format)", NSMakeRect(135, 192, 360, 22));
		[viewHeader addSubview:printHeaderShowDateCheck];

		// Explanation label
		NSTextField *lblNote = [[NSTextField alloc] initWithFrame:NSMakeRect(135, 148, 380, 38)];
		[lblNote setStringValue:@"When both Title and Date are enabled, Title appears on the left and Date on the right. When only one is enabled, it is centered."];
		[lblNote setBezeled:NO];
		[lblNote setDrawsBackground:NO];
		[lblNote setEditable:NO];
		[lblNote setSelectable:NO];
		[lblNote setFont:[NSFont systemFontOfSize:11.0]];
		[lblNote setTextColor:[NSColor secondaryLabelColor]];
		[viewHeader addSubview:lblNote];
		[lblNote release];

		// Separator line
		NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(20, 138, 500, 1)];
		[sep setBoxType:NSBoxSeparator];
		[viewHeader addSubview:sep];
		[sep release];

		// Page Numbers Location
		NSTextField *lblLoc = make_pref_label(@"Page Numbers:", NSMakeRect(10, 95, 120, 20));
		[viewHeader addSubview:lblLoc];
		[lblLoc release];
		printPageNumLocPopup = make_pref_popup(NSMakeRect(135, 92, 240, 26));
		[printPageNumLocPopup addItemWithTitle:@"None"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_NONE];
		[printPageNumLocPopup addItemWithTitle:@"Bottom Center (Standard)"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_BOTTOM_CENTER];
		[printPageNumLocPopup addItemWithTitle:@"Bottom Right"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_BOTTOM_RIGHT];
		[printPageNumLocPopup addItemWithTitle:@"Bottom Left"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_BOTTOM_LEFT];
		[printPageNumLocPopup addItemWithTitle:@"Top Center"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_TOP_CENTER];
		[printPageNumLocPopup addItemWithTitle:@"Top Right"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_TOP_RIGHT];
		[printPageNumLocPopup addItemWithTitle:@"Top Left"];
		[[printPageNumLocPopup lastItem] setTag:PRINTER_PAGE_NUM_TOP_LEFT];
		[viewHeader addSubview:printPageNumLocPopup];

		// Page Numbers Format
		NSTextField *lblFmt = make_pref_label(@"Format:", NSMakeRect(10, 55, 120, 20));
		[viewHeader addSubview:lblFmt];
		[lblFmt release];
		printPageNumFmtPopup = make_pref_popup(NSMakeRect(135, 52, 240, 26));
		[printPageNumFmtPopup addItemWithTitle:@"Page n of N  (e.g. Page 1 of 3)"];
		[[printPageNumFmtPopup lastItem] setTag:PRINTER_PAGE_NUM_FMT_PAGE_N_OF_TOTAL];
		[printPageNumFmtPopup addItemWithTitle:@"Page n  (e.g. Page 1)"];
		[[printPageNumFmtPopup lastItem] setTag:PRINTER_PAGE_NUM_FMT_PAGE_N];
		[printPageNumFmtPopup addItemWithTitle:@"n of N  (e.g. 1 of 3)"];
		[[printPageNumFmtPopup lastItem] setTag:PRINTER_PAGE_NUM_FMT_N_OF_TOTAL];
		[printPageNumFmtPopup addItemWithTitle:@"n  (e.g. 1)"];
		[[printPageNumFmtPopup lastItem] setTag:PRINTER_PAGE_NUM_FMT_N];
		[viewHeader addSubview:printPageNumFmtPopup];

		[tabView addTabViewItem:tabHeader];
		[tabHeader release];
		[tabView release];

		// Cancel button
		NSButton *btnCancel = make_pref_button(@"Cancel", NSMakeRect(375, 14, 90, 32), self, @selector(cancel:));
		[contentView addSubview:btnCancel];
		[btnCancel release];

		// Save button
		NSButton *btnSave = make_pref_button(@"Save", NSMakeRect(475, 14, 90, 32), self, @selector(save:));
		[btnSave setKeyEquivalent:@"\r"];
		[prefsWindow setDefaultButtonCell:[btnSave cell]];
		[contentView addSubview:btnSave];
		[btnSave release];
	}

	const char *p;
	p = xroar_get_rom_path();
	[romPathField setStringValue:p ? [NSString stringWithUTF8String:p] : @""];
	p = xroar_get_cart_path();
	[cartPathField setStringValue:p ? [NSString stringWithUTF8String:p] : @""];
	p = xroar_get_disk_path();
	[diskPathField setStringValue:p ? [NSString stringWithUTF8String:p] : @""];
	p = xroar_get_tape_path();
	[tapePathField setStringValue:p ? [NSString stringWithUTF8String:p] : @""];

	[printDestPopup selectItemWithTag:xroar_get_print_dest()];
	[printFamilyPopup selectItemWithTag:xroar_get_print_font_family()];

	float fsz = xroar_get_print_font_size();
	if (fsz <= 0.0f) fsz = 10.0f;
	if (fsz == (int)fsz) {
		[printSizeCombo setStringValue:[NSString stringWithFormat:@"%d", (int)fsz]];
	} else {
		[printSizeCombo setStringValue:[NSString stringWithFormat:@"%.1f", fsz]];
	}

	int mtag = (int)(xroar_get_print_margin() * 100.0f + 0.5f);
	[printMarginPopup selectItemWithTag:mtag];

	[printAutoflushPopup selectItemWithTag:xroar_get_print_autoflush_ms()];

	p = xroar_get_print_path();
	if (p && *p) {
		[printPathField setStringValue:[NSString stringWithUTF8String:p]];
	} else {
		[printPathField setStringValue:get_default_print_dir()];
	}

	p = xroar_get_print_header_title();
	[printHeaderTitleField setStringValue:p ? [NSString stringWithUTF8String:p] : @"kmsCoCo Listing"];
	[printHeaderShowTitleCheck setState:xroar_get_print_header_show_title() ? NSControlStateValueOn : NSControlStateValueOff];
	[printHeaderShowDateCheck setState:xroar_get_print_header_show_date() ? NSControlStateValueOn : NSControlStateValueOff];
	[printPageNumLocPopup selectItemWithTag:xroar_get_print_page_num_loc()];
	[printPageNumFmtPopup selectItemWithTag:xroar_get_print_page_num_fmt()];

	cocoa_super_all_keys = 1;
	[prefsWindow center];
	[prefsWindow makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
}

@end

@interface kmsCoCoPrintTextView : NSTextView
@property (nonatomic, assign) NSInteger totalPages;
@end

@implementation kmsCoCoPrintTextView

- (BOOL)knowsPageRange:(NSRangePointer)range {
	BOOL result = [super knowsPageRange:range];
	if (result && range) {
		self.totalPages = range->length;
	}
	return result;
}

- (void)drawPageBorderWithSize:(NSSize)borderSize {
	[super drawPageBorderWithSize:borderSize];

	NSPrintOperation *op = [NSPrintOperation currentOperation];
	if (!op) return;
	NSPrintInfo *printInfo = [op printInfo];

	CGFloat leftMargin = printInfo ? [printInfo leftMargin] : 36.0;
	CGFloat rightMargin = printInfo ? [printInfo rightMargin] : 36.0;
	CGFloat topMargin = printInfo ? [printInfo topMargin] : 36.0;
	CGFloat bottomMargin = printInfo ? [printInfo bottomMargin] : 36.0;

	CGFloat contentLeft = leftMargin;
	CGFloat contentRight = borderSize.width - rightMargin;
	CGFloat contentWidth = contentRight - contentLeft;
	if (contentWidth <= 0) contentWidth = borderSize.width;

	BOOL showTitle = xroar_get_print_header_show_title();
	BOOL showDate = xroar_get_print_header_show_date();
	int pageLoc = xroar_get_print_page_num_loc();
	int pageFmt = xroar_get_print_page_num_fmt();

	NSInteger curPage = [op currentPage];
	NSInteger totPages = self.totalPages > 0 ? self.totalPages : 1;
	if (curPage > totPages) totPages = curPage;

	NSString *pageStr = nil;
	switch (pageFmt) {
	case PRINTER_PAGE_NUM_FMT_PAGE_N:
		pageStr = [NSString stringWithFormat:@"Page %ld", (long)curPage];
		break;
	case PRINTER_PAGE_NUM_FMT_N_OF_TOTAL:
		pageStr = [NSString stringWithFormat:@"%ld of %ld", (long)curPage, (long)totPages];
		break;
	case PRINTER_PAGE_NUM_FMT_N:
		pageStr = [NSString stringWithFormat:@"%ld", (long)curPage];
		break;
	case PRINTER_PAGE_NUM_FMT_PAGE_N_OF_TOTAL:
	default:
		pageStr = [NSString stringWithFormat:@"Page %ld of %ld", (long)curPage, (long)totPages];
		break;
	}

	const char *cTitle = xroar_get_print_header_title();
	NSString *title = (cTitle && *cTitle) ? [NSString stringWithUTF8String:cTitle] : @"kmsCoCo Listing";

	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	[df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
	NSString *dateStr = [df stringFromDate:[NSDate date]];
	[df release];

	// Determine header items
	NSString *headerLeft = nil;
	NSString *headerCenter = nil;
	NSString *headerRight = nil;

	// Page number in top header?
	NSString *topPageStr = nil;
	if (pageLoc == PRINTER_PAGE_NUM_TOP_LEFT ||
	    pageLoc == PRINTER_PAGE_NUM_TOP_CENTER ||
	    pageLoc == PRINTER_PAGE_NUM_TOP_RIGHT) {
		topPageStr = pageStr;
	}

	if (showTitle && showDate) {
		headerLeft = title;
		headerRight = dateStr;
		if (pageLoc == PRINTER_PAGE_NUM_TOP_CENTER) {
			headerCenter = topPageStr;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_LEFT) {
			headerLeft = [NSString stringWithFormat:@"%@  •  %@", title, topPageStr];
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_RIGHT) {
			headerRight = [NSString stringWithFormat:@"%@  •  %@", topPageStr, dateStr];
		}
	} else if (showTitle) {
		if (pageLoc == PRINTER_PAGE_NUM_TOP_CENTER) {
			headerLeft = title;
			headerCenter = topPageStr;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_LEFT) {
			headerLeft = topPageStr;
			headerCenter = title;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_RIGHT) {
			headerCenter = title;
			headerRight = topPageStr;
		} else {
			headerCenter = title;
		}
	} else if (showDate) {
		if (pageLoc == PRINTER_PAGE_NUM_TOP_CENTER) {
			headerLeft = dateStr;
			headerCenter = topPageStr;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_LEFT) {
			headerLeft = topPageStr;
			headerCenter = dateStr;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_RIGHT) {
			headerCenter = dateStr;
			headerRight = topPageStr;
		} else {
			headerCenter = dateStr;
		}
	} else if (topPageStr) {
		if (pageLoc == PRINTER_PAGE_NUM_TOP_LEFT) {
			headerLeft = topPageStr;
		} else if (pageLoc == PRINTER_PAGE_NUM_TOP_RIGHT) {
			headerRight = topPageStr;
		} else {
			headerCenter = topPageStr;
		}
	}

	BOOL hasHeader = (headerLeft != nil || headerCenter != nil || headerRight != nil);

	// Determine footer items
	NSString *footerLeft = nil;
	NSString *footerCenter = nil;
	NSString *footerRight = nil;
	if (pageLoc == PRINTER_PAGE_NUM_BOTTOM_LEFT) {
		footerLeft = pageStr;
	} else if (pageLoc == PRINTER_PAGE_NUM_BOTTOM_CENTER) {
		footerCenter = pageStr;
	} else if (pageLoc == PRINTER_PAGE_NUM_BOTTOM_RIGHT) {
		footerRight = pageStr;
	}

	BOOL hasFooter = (footerLeft != nil || footerCenter != nil || footerRight != nil);

	if (!hasHeader && !hasFooter) return;

	NSFont *hFont = [NSFont systemFontOfSize:9.0];
	NSColor *hColor = [NSColor colorWithCalibratedWhite:0.25 alpha:1.0];

	NSMutableParagraphStyle *leftStyle = [[NSMutableParagraphStyle alloc] init];
	[leftStyle setAlignment:NSTextAlignmentLeft];
	[leftStyle setLineBreakMode:NSLineBreakByTruncatingTail];

	NSMutableParagraphStyle *centerStyle = [[NSMutableParagraphStyle alloc] init];
	[centerStyle setAlignment:NSTextAlignmentCenter];
	[centerStyle setLineBreakMode:NSLineBreakByTruncatingTail];

	NSMutableParagraphStyle *rightStyle = [[NSMutableParagraphStyle alloc] init];
	[rightStyle setAlignment:NSTextAlignmentRight];
	[rightStyle setLineBreakMode:NSLineBreakByTruncatingTail];

	NSDictionary *leftAttrs = @{ NSFontAttributeName: hFont, NSForegroundColorAttributeName: hColor, NSParagraphStyleAttributeName: leftStyle };
	NSDictionary *centerAttrs = @{ NSFontAttributeName: hFont, NSForegroundColorAttributeName: hColor, NSParagraphStyleAttributeName: centerStyle };
	NSDictionary *rightAttrs = @{ NSFontAttributeName: hFont, NSForegroundColorAttributeName: hColor, NSParagraphStyleAttributeName: rightStyle };

	// Draw Header
	if (hasHeader) {
		CGFloat lineY = borderSize.height - topMargin + 5.0;
		CGFloat headerY = borderSize.height - topMargin + 10.0;

		CGFloat rightWidth = 0;
		if (headerRight) {
			NSSize rSize = [headerRight sizeWithAttributes:rightAttrs];
			rightWidth = rSize.width + 4.0;
			NSRect rRect = NSMakeRect(contentRight - rightWidth, headerY, rightWidth, 14.0);
			[headerRight drawInRect:rRect withAttributes:rightAttrs];
		}

		CGFloat leftWidth = 0;
		if (headerLeft) {
			CGFloat avail = contentWidth - rightWidth - 10.0;
			if (avail < 50.0) avail = 50.0;
			NSSize lSize = [headerLeft sizeWithAttributes:leftAttrs];
			leftWidth = MIN(lSize.width + 4.0, avail);
			NSRect lRect = NSMakeRect(contentLeft, headerY, leftWidth, 14.0);
			[headerLeft drawInRect:lRect withAttributes:leftAttrs];
		}

		if (headerCenter) {
			CGFloat sideMax = MAX(leftWidth, rightWidth);
			CGFloat cWidth = contentWidth - 2.0 * sideMax - 16.0;
			if (cWidth < 60.0) cWidth = contentWidth;
			NSRect cRect = NSMakeRect(contentLeft + (contentWidth - cWidth) / 2.0, headerY, cWidth, 14.0);
			[headerCenter drawInRect:cRect withAttributes:centerAttrs];
		}

		// Divider rule
		[NSGraphicsContext saveGraphicsState];
		[NSBezierPath setDefaultLineWidth:0.5];
		[[NSColor colorWithCalibratedWhite:0.75 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(contentLeft, lineY)
		                          toPoint:NSMakePoint(contentRight, lineY)];
		[NSGraphicsContext restoreGraphicsState];
	}

	// Draw Footer
	if (hasFooter) {
		CGFloat footerY = (bottomMargin > 24.0) ? (bottomMargin - 22.0) : 8.0;
		NSRect fRect = NSMakeRect(contentLeft, footerY, contentWidth, 14.0);
		if (footerLeft) {
			[footerLeft drawInRect:fRect withAttributes:leftAttrs];
		}
		if (footerCenter) {
			[footerCenter drawInRect:fRect withAttributes:centerAttrs];
		}
		if (footerRight) {
			[footerRight drawInRect:fRect withAttributes:rightAttrs];
		}
	}

	[leftStyle release];
	[centerStyle release];
	[rightStyle release];
}

@end

static void cocoa_handle_print_job(NSString *text) {
	if (!text || [text length] == 0) return;

	int dest = xroar_get_print_dest();
	if (dest == PRINTER_DEST_NONE || dest == PRINTER_DEST_FILE || dest == PRINTER_DEST_PIPE) {
		return;
	}

	NSString *printDir = nil;
	const char *cpath = xroar_get_print_path();
	if (cpath && *cpath) {
		printDir = [NSString stringWithUTF8String:cpath];
	} else {
		printDir = get_default_print_dir();
	}
	printDir = [printDir stringByExpandingTildeInPath];

	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir = NO;
	if (![fm fileExistsAtPath:printDir isDirectory:&isDir]) {
		[fm createDirectoryAtPath:printDir withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	NSString *enteredName = nil;
	BOOL showTitle = xroar_get_print_header_show_title();
	BOOL showDate = xroar_get_print_header_show_date();

	if (dest == PRINTER_DEST_TEXT || dest == PRINTER_DEST_PDF) {
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setAlertStyle:NSAlertStyleInformational];
		if (dest == PRINTER_DEST_PDF) {
			[alert setMessageText:@"Save PDF Printout"];
		} else {
			[alert setMessageText:@"Save Text Printout"];
		}
		[alert setInformativeText:@"Enter a job or file name and select header options:"];
		[alert addButtonWithTitle:@"Save"];
		[alert addButtonWithTitle:@"Cancel"];

		NSView *accView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 84)];

		NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 54, 380, 24)];
		[nameField setBezeled:YES];
		[nameField setBezelStyle:NSTextFieldSquareBezel];
		[nameField setDrawsBackground:YES];
		[nameField setEditable:YES];
		[nameField setSelectable:YES];
		[nameField setPlaceholderString:@"Job / File Name"];
		const char *cTitle = xroar_get_print_header_title();
		NSString *lastTitle = (cTitle && *cTitle) ? [NSString stringWithUTF8String:cTitle] : @"kmsCoCo Listing";
		[nameField setStringValue:lastTitle];
		[accView addSubview:nameField];

		NSButton *titleCheck = [[NSButton alloc] initWithFrame:NSMakeRect(0, 28, 380, 20)];
		[titleCheck setButtonType:NSButtonTypeSwitch];
		[titleCheck setTitle:@"Include job / file name in page header"];
		[titleCheck setState:showTitle ? NSOnState : NSOffState];
		[accView addSubview:titleCheck];

		NSButton *dateCheck = [[NSButton alloc] initWithFrame:NSMakeRect(0, 4, 380, 20)];
		[dateCheck setButtonType:NSButtonTypeSwitch];
		[dateCheck setTitle:@"Include date / timestamp in page header"];
		[dateCheck setState:showDate ? NSOnState : NSOffState];
		[accView addSubview:dateCheck];

		[alert setAccessoryView:accView];
		[accView release];

		[alert layout];
		[alert.window setInitialFirstResponder:nameField];
		[nameField selectText:nil];

		[NSApp activateIgnoringOtherApps:YES];
		cocoa_super_all_keys = 1;
		NSModalResponse resp = [alert runModal];
		cocoa_super_all_keys = 0;

		if (resp != NSAlertFirstButtonReturn) {
			[nameField release];
			[titleCheck release];
			[dateCheck release];
			[alert release];
			return;
		}

		enteredName = [[nameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if ([enteredName length] == 0) {
			enteredName = @"kmsCoCo Listing";
		}
		showTitle = ([titleCheck state] == NSOnState);
		showDate = ([dateCheck state] == NSOnState);

		xroar_set_print_header_title([enteredName UTF8String]);
		xroar_set_print_header_show_title(showTitle);
		xroar_set_print_header_show_date(showDate);
		xroar_save_config_file();

		[nameField release];
		[titleCheck release];
		[dateCheck release];
		[alert release];
	} else {
		const char *cTitle = xroar_get_print_header_title();
		enteredName = (cTitle && *cTitle) ? [NSString stringWithUTF8String:cTitle] : @"kmsCoCo Listing";
	}

	NSString *safeFilename = [enteredName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
	safeFilename = [safeFilename stringByReplacingOccurrencesOfString:@":" withString:@"_"];
	safeFilename = [safeFilename stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
	safeFilename = [safeFilename stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([safeFilename length] == 0) {
		safeFilename = @"kmsCoCo_Listing";
	}

	if (dest == PRINTER_DEST_TEXT) {
		if (showTitle || showDate) {
			NSString *title = enteredName;
			NSDateFormatter *df = [[NSDateFormatter alloc] init];
			[df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
			NSString *dateStr = [df stringFromDate:[NSDate date]];
			[df release];

			NSString *headerLine = nil;
			int width = 80;
			if (showTitle && showDate) {
				int pad = width - (int)[title length] - (int)[dateStr length];
				if (pad < 2) pad = 2;
				NSString *spaces = [@"" stringByPaddingToLength:pad withString:@" " startingAtIndex:0];
				headerLine = [NSString stringWithFormat:@"%@%@%@", title, spaces, dateStr];
			} else if (showTitle) {
				int pad = (width - (int)[title length]) / 2;
				if (pad < 0) pad = 0;
				NSString *spaces = [@"" stringByPaddingToLength:pad withString:@" " startingAtIndex:0];
				headerLine = [NSString stringWithFormat:@"%@%@", spaces, title];
			} else {
				int pad = (width - (int)[dateStr length]) / 2;
				if (pad < 0) pad = 0;
				NSString *spaces = [@"" stringByPaddingToLength:pad withString:@" " startingAtIndex:0];
				headerLine = [NSString stringWithFormat:@"%@%@", spaces, dateStr];
			}
			NSString *divider = [@"" stringByPaddingToLength:width withString:@"-" startingAtIndex:0];
			text = [NSString stringWithFormat:@"%@\n%@\n\n%@", headerLine, divider, text];
		}

		NSString *targetFilename = safeFilename;
		if (![[targetFilename lowercaseString] hasSuffix:@".txt"]) {
			targetFilename = [targetFilename stringByAppendingString:@".txt"];
		}
		NSString *txtPath = [printDir stringByAppendingPathComponent:targetFilename];
		if ([fm fileExistsAtPath:txtPath]) {
			NSString *base = [targetFilename stringByDeletingPathExtension];
			int counter = 1;
			while ([fm fileExistsAtPath:txtPath]) {
				txtPath = [printDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%d.txt", base, counter++]];
			}
		}

		NSError *err = nil;
		BOOL ok = [text writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
		if (ok) {
			NSUserNotification *notif = [[NSUserNotification alloc] init];
			[notif setTitle:@"kmsCoCo Printout Saved"];
			[notif setInformativeText:[NSString stringWithFormat:@"Saved UTF-8 text to %@", [txtPath lastPathComponent]]];
			[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notif];
			[notif release];
			NSBeep();
		} else {
			NSLog(@"kmsCoCo: Failed to write text printout to %@: %@", txtPath, [err localizedDescription]);
		}
		return;
	}

	// Prepare font for PDF / Native Print Dialog
	int family = xroar_get_print_font_family();
	float fontSize = xroar_get_print_font_size();
	if (fontSize < 4.0f || fontSize > 144.0f) fontSize = 10.0f;

	NSFont *font = nil;
	switch (family) {
	case PRINTER_FONT_SERIF:
		font = [NSFont fontWithName:@"Times" size:fontSize];
		if (!font) font = [NSFont fontWithName:@"Georgia" size:fontSize];
		break;
	case PRINTER_FONT_SANS:
		font = [NSFont fontWithName:@"Helvetica" size:fontSize];
		if (!font) font = [NSFont systemFontOfSize:fontSize];
		break;
	case PRINTER_FONT_MONO:
	default:
		font = [NSFont fontWithName:@"Menlo" size:fontSize];
		if (!font) font = [NSFont fontWithName:@"Courier" size:fontSize];
		if (!font) font = [NSFont userFixedPitchFontOfSize:fontSize];
		break;
	}
	if (!font) {
		font = [NSFont userFixedPitchFontOfSize:fontSize];
	}

	NSPrintInfo *printInfo = [[NSPrintInfo sharedPrintInfo] copy];
	float marginInches = xroar_get_print_margin();
	if (marginInches < 0.1f) marginInches = 0.5f;
	CGFloat marginPts = marginInches * 72.0f;

	BOOL hasHeader = xroar_get_print_header_show_title() || xroar_get_print_header_show_date() ||
	                 (xroar_get_print_page_num_loc() >= PRINTER_PAGE_NUM_TOP_CENTER);
	BOOL hasFooter = (xroar_get_print_page_num_loc() >= PRINTER_PAGE_NUM_BOTTOM_CENTER &&
	                  xroar_get_print_page_num_loc() <= PRINTER_PAGE_NUM_BOTTOM_LEFT);

	CGFloat topMargin = marginPts;
	CGFloat bottomMargin = marginPts;
	if (hasHeader && topMargin < 42.0f) topMargin = 42.0f;
	if (hasFooter && bottomMargin < 36.0f) bottomMargin = 36.0f;

	[printInfo setLeftMargin:marginPts];
	[printInfo setRightMargin:marginPts];
	[printInfo setTopMargin:topMargin];
	[printInfo setBottomMargin:bottomMargin];
	[printInfo setHorizontallyCentered:NO];
	[printInfo setVerticallyCentered:NO];

	NSSize paperSize = [printInfo paperSize];
	CGFloat printableWidth = paperSize.width - [printInfo leftMargin] - [printInfo rightMargin];
	CGFloat printableHeight = paperSize.height - [printInfo topMargin] - [printInfo bottomMargin];
	if (printableWidth <= 0) printableWidth = 468.0f;
	if (printableHeight <= 0) printableHeight = 648.0f;

	NSTextStorage *textStorage = [[NSTextStorage alloc] initWithString:text];
	NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
	[textStorage addLayoutManager:layoutManager];
	NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(printableWidth, CGFLOAT_MAX)];
	[textContainer setWidthTracksTextView:YES];
	[layoutManager addTextContainer:textContainer];

	kmsCoCoPrintTextView *textView = [[kmsCoCoPrintTextView alloc] initWithFrame:NSMakeRect(0, 0, printableWidth, printableHeight) textContainer:textContainer];
	[textView setFont:font];
	[textView setTextColor:[NSColor blackColor]];
	[textView setBackgroundColor:[NSColor whiteColor]];

	if (dest == PRINTER_DEST_PDF) {
		NSString *targetFilename = safeFilename;
		if (![[targetFilename lowercaseString] hasSuffix:@".pdf"]) {
			targetFilename = [targetFilename stringByAppendingString:@".pdf"];
		}
		NSString *pdfPath = [printDir stringByAppendingPathComponent:targetFilename];
		if ([fm fileExistsAtPath:pdfPath]) {
			NSString *base = [targetFilename stringByDeletingPathExtension];
			int counter = 1;
			while ([fm fileExistsAtPath:pdfPath]) {
				pdfPath = [printDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%d.pdf", base, counter++]];
			}
		}

		NSMutableDictionary *dict = [printInfo dictionary];
		[dict setObject:NSPrintSaveJob forKey:NSPrintJobDisposition];
		[dict setObject:[NSURL fileURLWithPath:pdfPath] forKey:NSPrintJobSavingURL];

		NSPrintOperation *op = [NSPrintOperation printOperationWithView:textView printInfo:printInfo];
		[op setShowsPrintPanel:NO];
		[op setShowsProgressPanel:NO];
		[op runOperation];

		NSUserNotification *notif = [[NSUserNotification alloc] init];
		[notif setTitle:@"kmsCoCo Printout Saved"];
		[notif setInformativeText:[NSString stringWithFormat:@"PDF saved to %@", [pdfPath lastPathComponent]]];
		[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notif];
		[notif release];
		NSBeep();
	} else if (dest == PRINTER_DEST_PROMPT) {
		NSPrintOperation *op = [NSPrintOperation printOperationWithView:textView printInfo:printInfo];
		[op setShowsPrintPanel:YES];
		[op setShowsProgressPanel:YES];

		NSWindow *win = [NSApp mainWindow];
		if (win) {
			[op runOperationModalForWindow:win delegate:nil didRunSelector:NULL contextInfo:NULL];
		} else {
			[op runOperation];
		}
	}

	[textView release];
	[textContainer release];
	[layoutManager release];
	[textStorage release];
	[printInfo release];
}

static void cocoa_printer_job_completed(void *sptr, const char *text, size_t len) {
	(void)sptr;
	if (!text || len == 0) return;

	NSString *nsText = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
	if (!nsText) {
		nsText = [[NSString alloc] initWithBytes:text length:len encoding:NSISOLatin1StringEncoding];
	}
	if (!nsText) return;

	dispatch_async(dispatch_get_main_queue(), ^{
		cocoa_handle_print_job(nsText);
		[nsText release];
	});
}

static void cocoa_update_recent_menu(void) {
	if (!recent_menu) return;
	[recent_menu removeAllItems];

	if (num_recent_media == 0) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"No Recent Media" action:nil keyEquivalent:@""];
		[item setEnabled:NO];
		[recent_menu addItem:item];
		[item release];
		return;
	}

	for (int i = 0; i < num_recent_media; i++) {
		if (!recent_media_list[i].path) continue;
		NSString *typeLabel = @"";
		switch (recent_media_list[i].type) {
		case RECENT_MEDIA_CART:
			typeLabel = @"[Cartridge]";
			break;
		case RECENT_MEDIA_DISK:
			typeLabel = @"[Disk 1]";
			break;
		case RECENT_MEDIA_TAPE:
			typeLabel = @"[Cassette]";
			break;
		}
		NSString *pathStr = [NSString stringWithUTF8String:recent_media_list[i].path];
		NSString *filename = [pathStr lastPathComponent];
		NSString *title = [NSString stringWithFormat:@"%@   %@", filename, typeLabel];
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(do_open_recent:) keyEquivalent:@""];
		[item setTag:i];
		[item setToolTip:pathStr];
		[item setTarget:NSApp];
		[recent_menu addItem:item];
		[item release];
	}

	[recent_menu addItem:[NSMenuItem separatorItem]];

	NSMenuItem *clear_item = [[NSMenuItem alloc] initWithTitle:@"Clear Menu" action:@selector(do_clear_recent:) keyEquivalent:@""];
	[clear_item setTarget:NSApp];
	[recent_menu addItem:clear_item];
	[clear_item release];
}

static void cocoa_update_recent_menu_delegate(void *sptr) {
	(void)sptr;
	cocoa_update_recent_menu();
}

static void cocoa_check_coco_roms(void) {
	struct coco_rom_status status;
	check_coco_roms(&status);
	if (status.all_ok) {
		free_coco_rom_status(&status);
		return;
	}

	while (!status.all_ok) {
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setAlertStyle:NSAlertStyleWarning];
		[alert setMessageText:@"Tandy Color Computer System ROMs Missing"];

		NSMutableString *info = [NSMutableString string];
		[info appendString:@"kmsCoCo requires Tandy Color Computer system ROMs to operate:\n\n"];

		if (status.has_bas) {
			[info appendFormat:@"• Color BASIC: Found (%@)\n",
				[[NSString stringWithUTF8String:status.bas_path] lastPathComponent]];
		} else {
			[info appendString:@"• Color BASIC: MISSING (bas13.rom)\n"];
		}

		if (status.has_extbas) {
			[info appendFormat:@"• Extended Color BASIC: Found (%@)\n",
				[[NSString stringWithUTF8String:status.extbas_path] lastPathComponent]];
		} else {
			[info appendString:@"• Extended Color BASIC: MISSING (extbas11.rom)\n"];
		}

		if (status.has_rsdos) {
			[info appendFormat:@"• RS-DOS Cartridge: Found (%@)\n",
				[[NSString stringWithUTF8String:status.rsdos_path] lastPathComponent]];
		} else {
			[info appendString:@"• RS-DOS Cartridge: MISSING (disk11.rom)\n"];
		}

		[info appendString:@"\nPlease select a folder containing the required ROM images."];
		[alert setInformativeText:info];

		[alert addButtonWithTitle:@"Locate ROMs Folder…"];
		[alert addButtonWithTitle:@"Quit"];

		[NSApp activateIgnoringOtherApps:YES];
		cocoa_super_all_keys = 1;
		NSModalResponse resp = [alert runModal];
		cocoa_super_all_keys = 0;
		[alert release];

		if (resp == NSAlertSecondButtonReturn) {
			free_coco_rom_status(&status);
			exit(0);
		}

		NSOpenPanel *panel = [NSOpenPanel openPanel];
		[panel setTitle:@"Locate Color Computer System ROMs Folder"];
		[panel setPrompt:@"Select Folder"];
		[panel setCanChooseFiles:YES];
		[panel setCanChooseDirectories:YES];
		[panel setAllowsMultipleSelection:NO];

		NSString *suggested = nil;
		NSString *stuffPath = [NSHomeDirectory() stringByAppendingPathComponent:@"kmsCoCo Stuff"];
		BOOL isDir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:stuffPath isDirectory:&isDir] && isDir) {
			suggested = stuffPath;
		} else {
			suggested = [@"~/Library/XRoar/roms" stringByExpandingTildeInPath];
		}
		if (suggested && [[NSFileManager defaultManager] fileExistsAtPath:suggested isDirectory:&isDir] && isDir) {
			[panel setDirectoryURL:[NSURL fileURLWithPath:suggested isDirectory:YES]];
		}

		cocoa_super_all_keys = 1;
		NSModalResponse panelResp = [panel runModal];
		cocoa_super_all_keys = 0;

		if (panelResp == NSModalResponseOK) {
			NSURL *url = [[panel URLs] objectAtIndex:0];
			BOOL selectedIsDir = NO;
			NSString *chosenPath = [url path];
			if ([[NSFileManager defaultManager] fileExistsAtPath:chosenPath isDirectory:&selectedIsDir]) {
				NSString *folderPath = selectedIsDir ? chosenPath : [chosenPath stringByDeletingLastPathComponent];

				// Check if there is a 'roms' subdirectory inside folderPath
				NSString *romsSubdir = [folderPath stringByAppendingPathComponent:@"roms"];
				BOOL subIsDir = NO;
				BOOL hasRomsSubdir = ([[NSFileManager defaultManager] fileExistsAtPath:romsSubdir isDirectory:&subIsDir] && subIsDir);

				const char *cur = xroar_get_rom_path();
				NSString *newRomPath;
				if (hasRomsSubdir) {
					if (cur && *cur) {
						newRomPath = [NSString stringWithFormat:@"%@:%@:%s", folderPath, romsSubdir, cur];
					} else {
						newRomPath = [NSString stringWithFormat:@"%@:%@", folderPath, romsSubdir];
					}
				} else {
					if (cur && *cur) {
						newRomPath = [NSString stringWithFormat:@"%@:%s", folderPath, cur];
					} else {
						newRomPath = folderPath;
					}
				}
				xroar_set_rom_path([newRomPath UTF8String]);
				xroar_save_config_file();
			}
		}

		free_coco_rom_status(&status);
		check_coco_roms(&status);
	}

	free_coco_rom_status(&status);
}

@interface kmsCoCoApplication : NSApplication
@end

@implementation kmsCoCoApplication

- (void)sendEvent:(NSEvent *)anEvent {
	switch ([anEvent type]) {
		case NSEventTypeKeyDown:
		case NSEventTypeKeyUp:
			if (cocoa_super_all_keys || ([anEvent modifierFlags] & NSEventModifierFlagCommand) || [anEvent window] != [self mainWindow]) {
				[super sendEvent:anEvent];
			}
			break;
		default:
			[super sendEvent:anEvent];
			break;
	}
}

- (void)paste:(id)sender {
	(void)sender;
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	NSString *text = [pb stringForType:NSPasteboardTypeString];
	if (!text || [text length] == 0) return;

	if (xroar.auto_kbd) {
		if (![text hasSuffix:@"\n"] && ![text hasSuffix:@"\r"]) {
			text = [text stringByAppendingString:@"\r"];
		}
		const char *utf8 = [text UTF8String];
		if (utf8 && *utf8) {
			ak_type_string_len(xroar.auto_kbd, utf8, strlen(utf8));
		}
	}
}

- (void)do_type_text_file:(id)sender {
	(void)sender;
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setTitle:@"Select Text File to Type into BASIC"];
	[panel setPrompt:@"Type"];
	[panel setCanChooseFiles:YES];
	[panel setCanChooseDirectories:NO];
	[panel setAllowsMultipleSelection:NO];
	[panel setAllowedFileTypes:@[@"bas", @"txt", @"asc", @"text"]];

	cocoa_super_all_keys = 1;
	NSModalResponse resp = [panel runModal];
	cocoa_super_all_keys = 0;

	if (resp == NSModalResponseOK) {
		NSURL *url = [panel URL];
		if (url && [url isFileURL]) {
			NSString *path = [url path];
			if (path && xroar.auto_kbd) {
				ak_type_file(xroar.auto_kbd, [path UTF8String]);
			}
		}
	}
}

- (void)do_open_recent:(id)sender {
	int idx = (int)[sender tag];
	if (idx >= 0 && idx < num_recent_media) {
		const char *filepath = recent_media_list[idx].path;
		if (!filepath) return;
		if (access(filepath, R_OK) != 0) {
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setAlertStyle:NSAlertStyleWarning];
			[alert setMessageText:@"File Not Found"];
			[alert setInformativeText:[NSString stringWithFormat:@"The recent file \"%s\" could not be found or opened.", filepath]];
			[alert addButtonWithTitle:@"OK"];
			cocoa_super_all_keys = 1;
			[alert runModal];
			cocoa_super_all_keys = 0;
			[alert release];
			return;
		}

		char *path = xstrdup(filepath);
		enum recent_media_type type = recent_media_list[idx].type;
		switch (type) {
		case RECENT_MEDIA_CART:
			hk_scan_release(hk_scan_Shift_L);
			hk_scan_release(hk_scan_Shift_R);
			xroar_load_file_by_type(path, 1);
			break;
		case RECENT_MEDIA_DISK:
			xroar_insert_disk_file(0, path);
			break;
		case RECENT_MEDIA_TAPE:
			tape_deck_insert_file(path);
			[[kmsCoCoTapeDeckController sharedController] updateStatus];
			break;
		}
		free(path);
	}
}

- (void)do_clear_recent:(id)sender {
	(void)sender;
	recent_media_clear();
}

- (void)orderFrontPreferencesPanel:(id)sender {
	(void)sender;
	[[kmsCoCoPreferencesController sharedController] showPreferencesWindow];
}

- (void)orderFrontStandardAboutPanel:(id)sender {
	(void)sender;
	NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"kmscoco" ofType:@"icns"];
	NSImage *appIcon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
	if (!appIcon) {
		NSString *artworkPath = [[NSBundle mainBundle] pathForResource:@"about_artwork" ofType:@"png"];
		if (artworkPath) {
			appIcon = [[NSImage alloc] initWithContentsOfFile:artworkPath];
		}
	}

	NSString *creditsStr = @"Tandy Color Computer (CoCo 1) Emulator\n\n"
	                       @"Based on XRoar by Ciaran Anscomb\n"
	                       @"https://www.6809.org.uk/xroar/\n\n"
	                       @"Copyright © 2003-2026 Ciaran Anscomb and kmsCoCo contributors\n"
	                       @"Developed with assistance from Google Gemini & Antigravity\n\n"
	                       @"License: GNU General Public License version 3 or later\n"
	                       @"https://www.gnu.org/licenses/gpl-3.0.html";
	NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
	[style setAlignment:NSTextAlignmentCenter];
	NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont systemFontOfSize:11], NSFontAttributeName,
		style, NSParagraphStyleAttributeName,
		nil];
	NSAttributedString *creditsAttr = [[NSAttributedString alloc] initWithString:creditsStr attributes:attrs];
	[style release];

	NSMutableDictionary *options = [NSMutableDictionary dictionary];
	[options setObject:@"kmsCoCo" forKey:@"ApplicationName"];
	[options setObject:[NSString stringWithUTF8String:PACKAGE_VERSION] forKey:@"ApplicationVersion"];
	[options setObject:[NSString stringWithFormat:@"Version %@", [NSString stringWithUTF8String:PACKAGE_VERSION]] forKey:@"Version"];
	if (appIcon) {
		[options setObject:appIcon forKey:@"ApplicationIcon"];
	} else if ([NSApp applicationIconImage]) {
		[options setObject:[NSApp applicationIconImage] forKey:@"ApplicationIcon"];
	}
	[options setObject:creditsAttr forKey:@"Credits"];
	[creditsAttr release];

	[NSApp activateIgnoringOtherApps:YES];
	[super orderFrontStandardAboutPanelWithOptions:options];
	if (appIcon) [appIcon release];
}

+ (void)registerUserDefaults {
	NSDictionary *appDefaults = [[NSDictionary alloc] initWithObjectsAndKeys:
		[NSNumber numberWithBool:NO], @"AppleMomentumScrollSupported",
		[NSNumber numberWithBool:NO], @"ApplePressAndHoldEnabled",
		[NSNumber numberWithBool:YES], @"ApplePersistenceIgnoreState",
		nil];
	[[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
	[appDefaults release];
}

- (void)do_set_state:(id)sender {
	int sender_tag = [sender tag];
	int tag = UIMAC_TAG_TYPE(sender_tag);
	int value = UIMAC_TAG_VALUE(sender_tag);

	// Try and ensure that the keydown event that (maybe) caused this
	// menuitem dispatch is not then handled by the main loop as well.
	SDL_PumpEvents();
	SDL_FlushEvent(SDL_KEYDOWN);

	switch (tag) {

	/* Simple actions: */
	case ui_tag_action:
		switch (value) {
		case ui_action_quit:
			{
				SDL_Event event;
				event.type = SDL_QUIT;
				SDL_PushEvent(&event);
			}
			break;
		case ui_action_reset_soft:
			hk_scan_release(hk_scan_Shift_L);
			hk_scan_release(hk_scan_Shift_R);
			xroar_soft_reset();
			break;
		case ui_action_reset_hard:
			hk_scan_release(hk_scan_Shift_L);
			hk_scan_release(hk_scan_Shift_R);
			xroar_hard_reset();
			break;
		case ui_action_file_run:
			hk_scan_release(hk_scan_Shift_L);
			hk_scan_release(hk_scan_Shift_R);
			xroar_run_file();
			break;
		case ui_action_file_load:
			xroar_load_file();
			break;
		case ui_action_file_save_snapshot:
			xroar_save_snapshot();
			break;
#ifdef SCREENSHOT
		case ui_action_file_screenshot:
			xroar_screenshot();
			break;
#endif
		case ui_action_cart_insert:
			hk_scan_release(hk_scan_Shift_L);
			hk_scan_release(hk_scan_Shift_R);
			{
				char *filename = DELEGATE_CALL(xroar.ui_interface->filereq_interface->load_filename, "Run cartridge ROM");
				if (filename) {
					xroar_load_file_by_type(filename, 1);
					free(filename);
				}
			}
			break;
		case ui_action_tape_input:
			xroar_insert_input_tape();
			break;
		case ui_action_tape_output:
			xroar_insert_output_tape();
			break;
		case ui_action_tape_input_rewind:
			if (xroar.tape_interface->tape_input) {
				tape_seek(xroar.tape_interface->tape_input, 0, SEEK_SET);
			}
			break;
		case ui_action_print_flush:
			xroar_flush_printer();
			break;
		case ui_action_joystick_swap:
			ui_update_state(-1, ui_tag_joystick_cycle, 1, NULL);
			break;
		default:
			break;
		}
		break;

	/* Configuration: */
	case uimac_tag_config_save:
		xroar_save_config_file();
		break;
	case ui_tag_config_autosave:
		ui_update_state(-1, ui_tag_config_autosave, UI_NEXT, NULL);
		break;

	/* Machines: */
	case ui_tag_machine:
		ui_update_state(-1, ui_tag_machine, value, NULL);
		break;

	/* Cartridges: */
	case ui_tag_cartridge:
		ui_update_state(-1, ui_tag_cartridge, value, NULL);
		break;

	/* Cassettes: */
	case ui_tag_tape_flag_fast:
		ui_update_state(-1, ui_tag_tape_flag_fast, UI_NEXT, NULL);
		break;
	case ui_tag_tape_flag_pad_auto:
		ui_update_state(-1, ui_tag_tape_flag_pad_auto, UI_NEXT, NULL);
		break;
	case ui_tag_tape_flag_rewrite:
		ui_update_state(-1, ui_tag_tape_flag_rewrite, UI_NEXT, NULL);
		break;
	case ui_tag_tape_playing:
		ui_update_state(-1, ui_tag_tape_playing, UI_NEXT, NULL);
		break;

	/* Disks: */
	case ui_tag_disk_insert:
		xroar_insert_disk(value);
		break;
	case ui_tag_disk_new:
		xroar_new_disk(value);
		break;
	case ui_tag_disk_write_enable:
		ui_update_state(-1, ui_tag_disk_write_enable, UI_NEXT, (void *)(intptr_t)value);
		break;
	case ui_tag_disk_write_back:
		ui_update_state(-1, ui_tag_disk_write_back, UI_NEXT, (void *)(intptr_t)value);
		break;
	case ui_tag_disk_eject:
		xroar_eject_disk(value);
		break;
	case ui_tag_hd_filename:
		if (value >= 0 && value <= 1) {
			int hd = value;
			char *filename = DELEGATE_CALL(xroar.ui_interface->filereq_interface->load_filename, "Attach hard disk image");
			if (filename) {
				xroar_insert_hd_file(hd, filename);
				free(filename);
			}
		}
		break;
	case uimac_tag_hd_new:
		{
			int hd = value >> 4;
			int hd_type_index = value & 15;
			if (hd >= 0 && hd <= 1 && hd_type_index >= 0 && hd_type_index <= 3) {
				int hd_type = hd_type_map[hd_type_index];
				char *filename = DELEGATE_CALL(xroar.ui_interface->filereq_interface->save_filename, "Create hard disk image");
				if (filename) {
					if (bd_create(filename, hd_type)) {
						xroar_insert_hd_file(hd, filename);
					}
					free(filename);
				}
			}
		}
		break;
	case uimac_tag_hd_detach:
		if (value >= 0 && value <= 1) {
			int hd = value;
			xroar_insert_hd_file(hd, NULL);
		}
		break;

	// Printers:
	case ui_tag_print_destination:
		if (value == PRINTER_DESTINATION_FILE) {
			char *filename = DELEGATE_CALL(global_uisdl2->ui_interface.filereq_interface->save_filename, "Print to file");
			if (filename) {
				ui_update_state(-1, ui_tag_print_file, 0, filename);
				free(filename);
			}
		}
		ui_update_state(-1, ui_tag_print_destination, value, NULL);
		break;

	/* Video: */
	case ui_tag_cmp_fs:
		ui_update_state(-1, ui_tag_cmp_fs, value, NULL);
		break;
	case ui_tag_cmp_fsc:
		ui_update_state(-1, ui_tag_cmp_fsc, value, NULL);
		break;
	case ui_tag_cmp_system:
		ui_update_state(-1, ui_tag_cmp_system, value, NULL);
		break;
	case ui_tag_monochrome:
		ui_update_state(-1, ui_tag_monochrome, UI_NEXT, NULL);
		break;
	case ui_tag_cmp_colour_killer:
		ui_update_state(-1, ui_tag_cmp_colour_killer, UI_NEXT, NULL);
		break;
	case ui_tag_ccr:
		ui_update_state(-1, ui_tag_ccr, value, NULL);
		break;
	case ui_tag_picture:
		ui_update_state(-1, ui_tag_picture, value, NULL);
		break;
	case ui_tag_ntsc_scaling:
		ui_update_state(-1, ui_tag_ntsc_scaling, UI_NEXT, NULL);
		break;
	case ui_tag_tv_input:
		ui_update_state(-1, ui_tag_tv_input, value, NULL);
		break;
	case ui_tag_fullscreen:
		ui_update_state(-1, ui_tag_fullscreen, UI_NEXT, NULL);
		break;
	case ui_tag_vdg_inverse:
		ui_update_state(-1, ui_tag_vdg_inverse, UI_NEXT, NULL);
		break;
	case ui_tag_zoom:
		ui_update_state(-1, tag, value, NULL);
		break;

	/* Keyboard: */
	case ui_tag_keymap:
		ui_update_state(-1, ui_tag_keymap, value, NULL);
		break;

	// Tool
	case ui_tag_hkbd_layout:
		ui_update_state(-1, ui_tag_hkbd_layout, value, NULL);
		break;
	case ui_tag_hkbd_lang:
		ui_update_state(-1, ui_tag_hkbd_lang, value, NULL);
		break;
	case ui_tag_kbd_translate:
		ui_update_state(-1, ui_tag_kbd_translate, UI_NEXT, NULL);
		break;
	case ui_tag_ratelimit:
		ui_update_state(-1, ui_tag_ratelimit_latch, UI_NEXT, NULL);
		break;

	/* Joysticks: */
	case uimac_tag_joystick_right:
		ui_update_state(-1, ui_tag_joystick_port, 0, (void *)(intptr_t)value);
		break;
	case uimac_tag_joystick_left:
		ui_update_state(-1, ui_tag_joystick_port, 1, (void *)(intptr_t)value);
		break;

	default:
		break;
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
	if ([item action] == @selector(showKeyboardGuide:) ||
	    [item action] == @selector(orderFrontPreferencesPanel:) ||
	    [item action] == @selector(do_open_recent:) ||
	    [item action] == @selector(do_clear_recent:)) {
		return YES;
	}
	if ([item action] == nil) {
		return NO;
	}

	struct ui_macosx_interface *uimac = (struct ui_macosx_interface *)global_uisdl2;
	if (!uimac) {
		return YES;
	}

	int item_tag = [item tag];
	int tag = UIMAC_TAG_TYPE(item_tag);
	int value = UIMAC_TAG_VALUE(item_tag);

	switch (tag) {

	case ui_tag_config_autosave:
		[item setState:(uimac->config.autosave ? NSOnState : NSOffState)];
		break;

	case ui_tag_machine:
		[item setState:((value == uimac->machine.id) ? NSOnState : NSOffState)];
		break;

	case ui_tag_cartridge:
		[item setState:((value == uimac->cart.id) ? NSOnState : NSOffState)];
		break;

	case ui_tag_tape_flag_fast:
		[item setState:(uimac->tape.fast ? NSOnState : NSOffState)];
		break;
	case ui_tag_tape_flag_pad_auto:
		[item setState:(uimac->tape.pad_auto ? NSOnState : NSOffState)];
		break;
	case ui_tag_tape_flag_rewrite:
		[item setState:(uimac->tape.rewrite ? NSOnState : NSOffState)];
		break;
	case ui_tag_tape_playing:
		[item setState:(uimac->tape.playing ? NSOnState : NSOffState)];
		break;

	case ui_tag_disk_write_enable:
		[item setState:(uimac->disk.drive[value].write_enable ? NSOnState : NSOffState)];
		break;
	case ui_tag_disk_write_back:
		[item setState:(uimac->disk.drive[value].write_back ? NSOnState : NSOffState)];
		break;

	case ui_tag_print_destination:
		[item setState:((value == xroar_get_print_dest()) ? NSOnState : NSOffState)];
		break;

	case ui_tag_fullscreen:
		[item setState:(uimac->vo.fullscreen ? NSOnState : NSOffState)];
		break;
	case ui_tag_vdg_inverse:
		[item setState:(uimac->vo.invert_text ? NSOnState : NSOffState)];
		break;
	case ui_tag_ccr:
		[item setState:((value == uimac->vo.ccr) ? NSOnState : NSOffState)];
		break;
	case ui_tag_picture:
		[item setState:((value == uimac->vo.picture) ? NSOnState : NSOffState)];
		break;
	case ui_tag_ntsc_scaling:
		[item setState:((value == uimac->vo.ntsc_scaling) ? NSOnState : NSOffState)];
		break;
	case ui_tag_tv_input:
		[item setState:((value == uimac->vo.tv_input) ? NSOnState : NSOffState)];
		break;
	case ui_tag_cmp_fs:
		[item setState:((value == uimac->vo.cmp_fs) ? NSOnState : NSOffState)];
		break;
	case ui_tag_cmp_fsc:
		[item setState:((value == uimac->vo.cmp_fsc) ? NSOnState : NSOffState)];
		break;
	case ui_tag_cmp_system:
		[item setState:((value == uimac->vo.cmp_system) ? NSOnState : NSOffState)];
		break;
	case ui_tag_monochrome:
		[item setState:((uimac->vo.monochrome) ? NSOnState : NSOffState)];
		break;
	case ui_tag_cmp_colour_killer:
		[item setState:((uimac->vo.cmp_colour_killer) ? NSOnState : NSOffState)];
		break;

	case ui_tag_keymap:
		[item setState:((value == uimac->machine.keymap) ? NSOnState : NSOffState)];
		break;
	case ui_tag_hkbd_layout:
		[item setState:((value == uimac->kbd.layout) ? NSOnState : NSOffState)];
		break;
	case ui_tag_hkbd_lang:
		[item setState:((value == uimac->kbd.lang) ? NSOnState : NSOffState)];
		break;
	case ui_tag_kbd_translate:
		[item setState:(uimac->kbd.translate ? NSOnState : NSOffState)];
		break;
	case ui_tag_ratelimit:
		[item setState:(uimac->misc.ratelimit_latch ? NSOnState : NSOffState)];
		break;

	case uimac_tag_joystick_right:
		[item setState:((value == uimac->joy.id[0]) ? NSOnState : NSOffState)];
		break;
	case uimac_tag_joystick_left:
		[item setState:((value == uimac->joy.id[1]) ? NSOnState : NSOffState)];
		break;

	}
	return YES;
}

- (void)showKeyboardGuide:(id)sender {
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:@"kmsCoCo Keyboard Guide"];
	[alert setInformativeText:
		@"Key Mappings for Modern Keyboards:\n\n"
		@"• Break: Escape\n"
		@"• Clear: F12 or Home\n"
		@"• Backspace / Delete: CoCo Left arrow / Backspace\n"
		@"• Directional Arrows: Up, Down, Left, Right\n"
		@"• Caps Lock: Caps Lock key (or Shift + 0)\n\n"
		@"Keyboard translation is permanently enabled: typing modern symbols (@, :, \", *, +, =) directly enters the corresponding CoCo character."];
	[alert addButtonWithTitle:@"OK"];
	[alert runModal];
	[alert release];
}

- (void)showTapeDeck:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] showTapeDeckWindow];
}

- (void)insertTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] insertTapeAction:sender];
}

- (void)newTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] newTapeAction:sender];
}

- (void)ejectTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] ejectTapeAction:sender];
}

@end

/* The main class of the application, the application's delegate */
@implementation SDLMain

- (void)orderFrontStandardAboutPanel:(id)sender {
	[NSApp orderFrontStandardAboutPanel:sender];
}

- (void)showTapeDeck:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] showTapeDeckWindow];
}

- (void)insertTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] insertTapeAction:sender];
}

- (void)newTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] newTapeAction:sender];
}

- (void)ejectTapeAction:(id)sender {
	(void)sender;
	[[kmsCoCoTapeDeckController sharedController] ejectTapeAction:sender];
}

/* Set the working directory to the .app's parent directory */
- (void)setupWorkingDirectory:(BOOL)shouldChdir {
	if (shouldChdir) {
		char parentdir[MAXPATHLEN];
		CFURLRef url = CFBundleCopyBundleURL(CFBundleGetMainBundle());
		CFURLRef url2 = CFURLCreateCopyDeletingLastPathComponent(0, url);
		if (CFURLGetFileSystemRepresentation(url2, 1, (UInt8 *)parentdir, MAXPATHLEN)) {
			chdir(parentdir);   /* chdir to the binary app's parent */
		}
		CFRelease(url);
		CFRelease(url2);
	}
}

static void setApplicationMenu(void) {
	/* warning: this code is very odd */
	NSMenu *apple_menu;
	NSMenuItem *item;
	NSString *title;
	NSString *app_name;

	app_name = get_application_name();
	apple_menu = [[NSMenu alloc] initWithTitle:@""];

	/* Add menu items */
	title = [@"About " stringByAppendingString:app_name];
	item = [[NSMenuItem alloc] initWithTitle:title action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
	[item setTarget:NSApp];
	[apple_menu addItem:item];
	[item release];

	[apple_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Preferences…" action:@selector(orderFrontPreferencesPanel:) keyEquivalent:@","];
	[item setTarget:NSApp];
	[apple_menu addItem:item];
	[item release];

	[apple_menu addItem:[NSMenuItem separatorItem]];

	title = [@"Hide " stringByAppendingString:app_name];
	[apple_menu addItemWithTitle:title action:@selector(hide:) keyEquivalent:@"h"];

	item = (NSMenuItem *)[apple_menu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	[item setKeyEquivalentModifierMask:(NSEventModifierFlagOption|NSEventModifierFlagCommand)];

	[apple_menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];

	[apple_menu addItem:[NSMenuItem separatorItem]];

	title = [@"Quit " stringByAppendingString:app_name];
	item = [[NSMenuItem alloc] initWithTitle:title action:@selector(do_set_state:) keyEquivalent:@"q"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_quit)];
	[apple_menu addItem:item];

	/* Put menu into the menubar */
	item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	[item setSubmenu:apple_menu];
	[[NSApp mainMenu] addItem:item];

	/* Tell the application object that this is now the application menu */
	[NSApp setAppleMenu:apple_menu];

	/* Finally give up our references to the objects */
	[apple_menu release];
	[item release];
}

static NSMenu *cartridge_menu;

/* Create File menu */
static void setup_file_menu(void) {
	NSMenu *file_menu;
	NSMenuItem *file_menu_item;
	NSMenuItem *item;
	NSMenu *submenu;
	NSString *tmp;

	file_menu = [[NSMenu alloc] initWithTitle:@"File"];

	tmp = [NSString stringWithFormat:@"Run%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@"L"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_file_run)];
	[file_menu addItem:item];
	[item release];
	[tmp release];

	tmp = [NSString stringWithFormat:@"Load%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@"l"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_file_load)];
	[file_menu addItem:item];
	[item release];
	[tmp release];

	tmp = [NSString stringWithFormat:@"Type text file%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_type_text_file:) keyEquivalent:@"T"];
	[item setTarget:NSApp];
	[file_menu addItem:item];
	[item release];
	[tmp release];

	[file_menu addItem:[NSMenuItem separatorItem]];

	recent_menu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
	item = [[NSMenuItem alloc] initWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
	[item setSubmenu:recent_menu];
	[file_menu addItem:item];
	[item release];

	[file_menu addItem:[NSMenuItem separatorItem]];

	cartridge_menu = [[NSMenu alloc] initWithTitle:@"Cartridge"];
	item = [[NSMenuItem alloc] initWithTitle:@"Cartridge" action:nil keyEquivalent:@""];
	[item setSubmenu:cartridge_menu];
	[file_menu addItem:item];
	[item release];

	[file_menu addItem:[NSMenuItem separatorItem]];

	submenu = [[NSMenu alloc] initWithTitle:@"Cassette"];

	tmp = [NSString stringWithFormat:@"Retro Cassette Deck%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(showTapeDeck:) keyEquivalent:@"k"];
	[submenu addItem:item];
	[item release];

	[submenu addItem:[NSMenuItem separatorItem]];

	tmp = [NSString stringWithFormat:@"Insert Cassette%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(insertTapeAction:) keyEquivalent:@""];
	[submenu addItem:item];
	[item release];

	tmp = [NSString stringWithFormat:@"New Blank Cassette%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(newTapeAction:) keyEquivalent:@""];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Eject Cassette" action:@selector(ejectTapeAction:) keyEquivalent:@""];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Cassette" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[file_menu addItem:item];
	[item release];

	[file_menu addItem:[NSMenuItem separatorItem]];

	for (int drive = 0; drive < 4; ++drive) {
		NSString *title = [NSString stringWithFormat:@"Drive %d", drive+1];
		NSString *key1 = [NSString stringWithFormat:@"%d", drive+1];
		NSString *key2 = [NSString stringWithFormat:@"%d", drive+5];

		submenu = [[NSMenu alloc] initWithTitle:title];

		tmp = [NSString stringWithFormat:@"Insert disk%C", 0x2026];
		item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:key1];
		[item setTag:UIMAC_TAGV(ui_tag_disk_insert, drive)];
		[submenu addItem:item];
		[item release];
		[tmp release];

		tmp = [NSString stringWithFormat:@"New disk%C", 0x2026];
		item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:key1];
		[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
		[item setTag:UIMAC_TAGV(ui_tag_disk_new, drive)];
		[submenu addItem:item];
		[item release];
		[tmp release];

		[submenu addItem:[NSMenuItem separatorItem]];

		item = [[NSMenuItem alloc] initWithTitle:@"Write enable" action:@selector(do_set_state:) keyEquivalent:key2];
		[item setTag:UIMAC_TAGV(ui_tag_disk_write_enable, drive)];
		[submenu addItem:item];
		[item release];

		item = [[NSMenuItem alloc] initWithTitle:@"Write back" action:@selector(do_set_state:) keyEquivalent:key2];
		[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
		[item setTag:UIMAC_TAGV(ui_tag_disk_write_back, drive)];
		[submenu addItem:item];
		[item release];

		[submenu addItem:[NSMenuItem separatorItem]];

		tmp = [NSString stringWithFormat:@"Eject disk%C", 0x2026];
		item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@""];
		[item setTag:UIMAC_TAGV(ui_tag_disk_eject, drive)];
		[submenu addItem:item];
		[item release];
		[tmp release];

		item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
		[item setSubmenu:submenu];
		[file_menu addItem:item];
		[item release];

		[key2 release];
		[key1 release];
		[title release];
	}

	[file_menu addItem:[NSMenuItem separatorItem]];

	submenu = [[NSMenu alloc] initWithTitle:@"Printer"];

	item = [[NSMenuItem alloc] initWithTitle:@"Native Print Dialog / PDF…" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_print_destination, PRINTER_DESTINATION_PROMPT)];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Auto-Save to PDF" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_print_destination, PRINTER_DESTINATION_PDF)];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Auto-Save to UTF-8 Text File" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_print_destination, PRINTER_DESTINATION_TEXT)];
	[submenu addItem:item];
	[item release];

	tmp = [NSString stringWithFormat:@"Raw Output to File%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_print_destination, PRINTER_DESTINATION_FILE)];
	[submenu addItem:item];
	[item release];
	[tmp release];

	item = [[NSMenuItem alloc] initWithTitle:@"Disabled" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_print_destination, PRINTER_DESTINATION_NONE)];
	[submenu addItem:item];
	[item release];

	[submenu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Flush Print Buffer Now" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_print_flush)];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Printer" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[file_menu addItem:item];
	[item release];

	[file_menu addItem:[NSMenuItem separatorItem]];

	tmp = [NSString stringWithFormat:@"Save snapshot%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@"s"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_file_save_snapshot)];
	[file_menu addItem:item];
	[item release];
	[tmp release];

#ifdef SCREENSHOT
	[file_menu addItem:[NSMenuItem separatorItem]];

	tmp = [NSString stringWithFormat:@"Screenshot to PNG%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_file_screenshot)];
	[file_menu addItem:item];
	[item release];
	[tmp release];
#endif

	[file_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Save configuration" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAG(uimac_tag_config_save)];
	[file_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Autosave configuration" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAG(ui_tag_config_autosave)];
	[file_menu addItem:item];
	[item release];

	file_menu_item = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
	[file_menu_item setSubmenu:file_menu];
	[[NSApp mainMenu] addItem:file_menu_item];
	[file_menu_item release];

	cocoa_update_recent_menu();
}

static void setup_edit_menu(void) {
	NSMenu *edit_menu;
	NSMenuItem *edit_menu_item;
	NSMenuItem *item;

	edit_menu = [[NSMenu alloc] initWithTitle:@"Edit"];

	item = [[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
	[edit_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
	[edit_menu addItem:item];
	[item release];

	[edit_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
	[edit_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[item setTarget:NSApp];
	[edit_menu addItem:item];
	[item release];

	[edit_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
	[edit_menu addItem:item];
	[item release];

	edit_menu_item = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
	[edit_menu_item setSubmenu:edit_menu];
	[[NSApp mainMenu] addItem:edit_menu_item];
	[edit_menu_item release];
	[edit_menu release];
}

static NSMenu *view_menu;

/* Create View menu */
static void setup_view_menu(void) {
	NSMenuItem *view_menu_item;
	NSMenuItem *item;
	NSMenu *submenu;

	view_menu = [[NSMenu alloc] initWithTitle:@"View"];

	submenu = [[NSMenu alloc] initWithTitle:@"TV input"];
	cocoa_update_radio_menu_from_enum(submenu, machine_tv_input_list, ui_tag_tv_input);
	item = [[NSMenuItem alloc] initWithTitle:@"TV input" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Picture area"];
	cocoa_update_radio_menu_from_enum(submenu, vo_viewport_list, ui_tag_picture);
	item = [[NSMenuItem alloc] initWithTitle:@"Picture area" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"60Hz scaling" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
	[item setTag:UIMAC_TAG(ui_tag_ntsc_scaling)];
	[view_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Composite rendering"];
	cocoa_update_radio_menu_from_enum(submenu, vo_cmp_ccr_list, ui_tag_ccr);
	item = [[NSMenuItem alloc] initWithTitle:@"Composite rendering" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Composite F(s)"];
	cocoa_update_radio_menu_from_enum(submenu, vo_render_fs_list, ui_tag_cmp_fs);
	item = [[NSMenuItem alloc] initWithTitle:@"Composite F(s)" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Composite F(sc)"];
	cocoa_update_radio_menu_from_enum(submenu, vo_render_fsc_list, ui_tag_cmp_fsc);
	item = [[NSMenuItem alloc] initWithTitle:@"Composite F(sc)" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Composite system"];
	cocoa_update_radio_menu_from_enum(submenu, vo_render_system_list, ui_tag_cmp_system);
	item = [[NSMenuItem alloc] initWithTitle:@"Composite system" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Colour killer" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
	[item setTag:UIMAC_TAG(ui_tag_cmp_colour_killer)];
	[view_menu addItem:item];
	[item release];

	[view_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Inverse text" action:@selector(do_set_state:) keyEquivalent:@"i"];
	[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagShift];
	[item setTag:UIMAC_TAG(ui_tag_vdg_inverse)];
	[view_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Monochrome" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAG(ui_tag_monochrome)];
	[view_menu addItem:item];
	[item release];

	[view_menu addItem:[NSMenuItem separatorItem]];

	submenu = [[NSMenu alloc] initWithTitle:@"Zoom"];

	item = [[NSMenuItem alloc] initWithTitle:@"Zoom in" action:@selector(do_set_state:) keyEquivalent:@"+"];
	[item setTag:UIMAC_TAGV(ui_tag_zoom, UI_NEXT)];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Zoom out" action:@selector(do_set_state:) keyEquivalent:@"-"];
	[item setTag:UIMAC_TAGV(ui_tag_zoom, UI_PREV)];
	[submenu addItem:item];
	[item release];

	[submenu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Reset" action:@selector(do_set_state:) keyEquivalent:@"0"];
	[item setTag:UIMAC_TAGV(ui_tag_zoom, 0)];
	[submenu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Zoom" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[view_menu addItem:item];
	[item release];

	[view_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Full screen" action:@selector(do_set_state:) keyEquivalent:@"f"];
	[item setTag:UIMAC_TAG(ui_tag_fullscreen)];
	[view_menu addItem:item];
	[item release];

	view_menu_item = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
	[view_menu_item setSubmenu:view_menu];
	[[NSApp mainMenu] addItem:view_menu_item];
	[view_menu_item release];
}

static NSMenu *machine_menu;
static NSMenu *joy_right_menu;
static NSMenu *joy_left_menu;

/* Create Hardware menu */
static void setup_hardware_menu(void) {
	NSMenu *hardware_menu;
	NSMenuItem *hardware_menu_item;
	NSMenuItem *item;

	hardware_menu = [[NSMenu alloc] initWithTitle:@"Hardware"];

	joy_right_menu = [[NSMenu alloc] initWithTitle:@"Right joystick"];
	item = [[NSMenuItem alloc] initWithTitle:@"Right joystick" action:nil keyEquivalent:@""];
	[item setSubmenu:joy_right_menu];
	[hardware_menu addItem:item];
	[item release];

	joy_left_menu = [[NSMenu alloc] initWithTitle:@"Left joystick"];
	item = [[NSMenuItem alloc] initWithTitle:@"Left joystick" action:nil keyEquivalent:@""];
	[item setSubmenu:joy_left_menu];
	[hardware_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Swap joysticks" action:@selector(do_set_state:) keyEquivalent:@"J"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_joystick_swap)];
	[hardware_menu addItem:item];
	[item release];

	[hardware_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Soft reset" action:@selector(do_set_state:) keyEquivalent:@"r"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_reset_soft)];
	[hardware_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Hard reset" action:@selector(do_set_state:) keyEquivalent:@"R"];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_reset_hard)];
	[hardware_menu addItem:item];
	[item release];

	[hardware_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Retro Cassette Deck…" action:@selector(showTapeDeck:) keyEquivalent:@"k"];
	[hardware_menu addItem:item];
	[item release];

	hardware_menu_item = [[NSMenuItem alloc] initWithTitle:@"Hardware" action:nil keyEquivalent:@""];
	[hardware_menu_item setSubmenu:hardware_menu];
	[[NSApp mainMenu] addItem:hardware_menu_item];
	[hardware_menu_item release];
}

/* Create Tool menu */
static void setup_tool_menu(void) {
	NSMenu *tool_menu;
	NSMenuItem *tool_menu_item;
	NSMenuItem *item;
	NSMenu *submenu;

	tool_menu = [[NSMenu alloc] initWithTitle:@"Tool"];

	submenu = [[NSMenu alloc] initWithTitle:@"Keyboard layout"];
	cocoa_update_radio_menu_from_enum(submenu, hkbd_layout_list, ui_tag_hkbd_layout);
	item = [[NSMenuItem alloc] initWithTitle:@"Keyboard layout" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[tool_menu addItem:item];
	[item release];

	submenu = [[NSMenu alloc] initWithTitle:@"Keyboard language"];
	cocoa_update_radio_menu_from_enum(submenu, hkbd_lang_list, ui_tag_hkbd_lang);
	item = [[NSMenuItem alloc] initWithTitle:@"Keyboard language" action:nil keyEquivalent:@""];
	[item setSubmenu:submenu];
	[tool_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"kmsCoCo Keyboard Guide..." action:@selector(showKeyboardGuide:) keyEquivalent:@"?"];
	[item setTarget:NSApp];
	[tool_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Rate limit" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAG(ui_tag_ratelimit)];
	[tool_menu addItem:item];
	[item release];

	tool_menu_item = [[NSMenuItem alloc] initWithTitle:@"Tool" action:nil keyEquivalent:@""];
	[tool_menu_item setSubmenu:tool_menu];
	[[NSApp mainMenu] addItem:tool_menu_item];
	[tool_menu_item release];
}

/* Create a window menu */
static void setup_window_menu(void) {
	NSMenu *window_menu;
	NSMenuItem *window_menu_item;
	NSMenuItem *item;

	window_menu = [[NSMenu alloc] initWithTitle:@"Window"];

	/* "Minimize" item */
	item = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[window_menu addItem:item];
	[item release];

	/* Put menu into the menubar */
	window_menu_item = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
	[window_menu_item setSubmenu:window_menu];
	[[NSApp mainMenu] addItem:window_menu_item];

	/* Tell the application object that this is now the window menu */
	[NSApp setWindowsMenu:window_menu];

	/* Finally give up our references to the objects */
	[window_menu release];
	[window_menu_item release];
}

/* Create Help menu */
static void setup_help_menu(void) {
	NSMenu *help_menu;
	NSMenuItem *help_menu_item;
	NSMenuItem *item;

	help_menu = [[NSMenu alloc] initWithTitle:@"Help"];
	[help_menu setAutoenablesItems:NO];

	item = [[NSMenuItem alloc] initWithTitle:@"kmsCoCo Keyboard Guide..." action:@selector(showKeyboardGuide:) keyEquivalent:@"?"];
	[item setTarget:NSApp];
	[item setEnabled:YES];
	[help_menu addItem:item];
	[item release];

	[help_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"Break: Escape" action:nil keyEquivalent:@""];
	[item setEnabled:NO];
	[help_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Clear: F12 or Home" action:nil keyEquivalent:@""];
	[item setEnabled:NO];
	[help_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Backspace: Left arrow" action:nil keyEquivalent:@""];
	[item setEnabled:NO];
	[help_menu addItem:item];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"Caps Lock: Caps Lock key (or Shift+0)" action:nil keyEquivalent:@""];
	[item setEnabled:NO];
	[help_menu addItem:item];
	[item release];

	help_menu_item = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
	[help_menu_item setSubmenu:help_menu];
	[[NSApp mainMenu] addItem:help_menu_item];
	[help_menu_item release];

	[NSApp setHelpMenu:help_menu];
	[help_menu release];
}

#if 0
/* Replacement for NSApplicationMain */
static void CustomApplicationMain(int argc, char **argv) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	SDLMain *sdlMain;

	(void)argc;
	(void)argv;

	/* Create SDLMain and make it the app delegate */
	sdlMain = [[SDLMain alloc] init];
	[NSApp setDelegate:sdlMain];

	/* Start the main event loop */
	[NSApp run];

	[sdlMain release];
	[pool release];
}
#endif

/*
 * Catch document open requests...this lets us notice files when the app was
 * launched by double-clicking a document, or when a document was
 * dragged/dropped on the app's icon. You need to have a CFBundleDocumentsType
 * section in your Info.plist to get this message, apparently.
 *
 * Files are added to gArgv, so to the app, they'll look like command line
 * arguments. Previously, apps launched from the finder had nothing but an
 * argv[0].
 *
 * This message may be received multiple times to open several docs on launch.
 *
 * This message is ignored once the app's mainline has been called.
 */
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename {
	const char *temparg;
	size_t arglen;
	char *arg;
	char **newargv;

	(void)theApplication;

	if (!gFinderLaunch)  /* MacOS is passing command line args. */
		return FALSE;

	if (gCalledAppMainline) {
		const char *cpath = [filename UTF8String];
		if (cpath) {
			xroar_load_file_by_type(cpath, 1);
			return TRUE;
		}
		return FALSE;
	}

	temparg = [filename UTF8String];
	arglen = SDL_strlen(temparg) + 1;
	arg = (char *)SDL_malloc(arglen);
	if (arg == NULL)
		return FALSE;

	newargv = (char **)realloc(gArgv, sizeof(char *) * (gArgc + 2));
	if (newargv == NULL) {
		SDL_free(arg);
		return FALSE;
	}
	gArgv = newargv;

	SDL_strlcpy(arg, temparg, arglen);
	gArgv[gArgc++] = arg;
	gArgv[gArgc] = NULL;
	return TRUE;
}


/* Called when the internal event loop has just started running */
- (void)applicationDidFinishLaunching: (NSNotification *)note {
	(void)note;
	// Set the working directory to the .app's parent directory
	[self setupWorkingDirectory:gFinderLaunch];
	/* Doesn't seem present in SDL2:
	// Pass keypresses etc. to Cocoa
	setenv("SDL_ENABLEAPPEVENTS", "1", 1); */
	// Hand off to main application code
	gCalledAppMainline = TRUE;

	// Seems to be necessary to make the menu bar work (without it, you
	// have to focus something else then return).  I'm sure there's a good
	// reason for that.
	[NSApp activateIgnoringOtherApps:YES];
	[kmsCoCoApplication registerUserDefaults];
}

@end

/* Called from ui_sdl_new() _before_ initialising SDL video. */
void cocoa_register_app(void) {

	// Ensure the application object is initialised
	[kmsCoCoApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

	// Set up the menubar
	[NSApp setMainMenu:[[NSMenu alloc] init]];
	setApplicationMenu();
	setup_file_menu();
	setup_edit_menu();
	setup_view_menu();
	setup_hardware_menu();
	setup_tool_menu();
	setup_window_menu();
	setup_help_menu();

	[NSApp finishLaunching];

	// More recent macosx adds some weird tab bar stuff to the view menu by
	// default.  I'm sure they had a good reason...
	[NSWindow setAllowsAutomaticWindowTabbing: NO];

	SDLMain *appDelegate = [[SDLMain alloc] init];
	[(NSApplication *)NSApp setDelegate:appDelegate];
}

#if 0
#ifdef main
#  undef main
#endif


/* Main entry point to executable - should *not* be SDL_main! */
int main(int argc, char **argv) {
	/* Copy the arguments into a global variable */
	/* This is passed if we are launched by double-clicking */
	if (argc >= 2 && strncmp(argv[1], "-psn", 4) == 0) {
		gArgv = (char **)SDL_malloc(sizeof(char *) * 2);
		gArgv[0] = argv[0];
		gArgv[1] = NULL;
		gArgc = 1;
		gFinderLaunch = YES;
	} else {
		int i;
		gArgc = argc;
		gArgv = (char **)SDL_malloc(sizeof(char *) * (argc+1));
		for (i = 0; i <= argc; i++)
			gArgv[i] = argv[i];
		gFinderLaunch = NO;
	}

	CustomApplicationMain(argc, argv);
	return 0;
}
#endif

// -------------------------------------------------------------------------

// XRoar UI definition

static void *ui_cocoa_new(void *cfg);
static void ui_cocoa_free(void *);

struct ui_module ui_cocoa_module = {
	.common = { .name = "macosx", .description = "Mac OS X+ SDL2 UI",
		.new = ui_cocoa_new,
	},
	.joystick_module_list = sdl_js_modlist,
};

static void cocoa_update_machine_menu(void *);
static void cocoa_update_cartridge_menu(void *);
static void cocoa_update_joystick_menus(void *);
static void cocoa_ui_state_notify(void *, int tag, void *smsg);

static void *ui_cocoa_new(void *cfg) {
	struct ui_cfg *ui_cfg = cfg;

	cocoa_register_app();

	struct ui_macosx_interface *uimac = (struct ui_macosx_interface *)ui_sdl_allocate(sizeof(*uimac));
	if (!uimac) {
		return NULL;
	}
	*uimac = (struct ui_macosx_interface){0};
	struct ui_sdl2_interface *uisdl2 = &uimac->ui_sdl2_interface;
	ui_sdl_init(uisdl2, ui_cfg);
	struct ui_interface *ui = &uisdl2->ui_interface;
	ui->free = DELEGATE_AS0(void, ui_cocoa_free, uimac);
	ui->update_machine_menu = DELEGATE_AS0(void, cocoa_update_machine_menu, uimac);
	ui->update_cartridge_menu = DELEGATE_AS0(void, cocoa_update_cartridge_menu, uimac);
	ui->update_joystick_menus = DELEGATE_AS0(void, cocoa_update_joystick_menus, uimac);
	ui->update_recent_menu = DELEGATE_AS0(void, cocoa_update_recent_menu_delegate, uimac);
	ui->printer_job_completed = DELEGATE_AS2(void, charcp, size_t, cocoa_printer_job_completed, uimac);

	// Register with messenger
	uimac->msgr_client_id = messenger_client_register();

	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_machine, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_cartridge, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_flag_fast, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_flag_pad_auto, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_flag_rewrite, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_playing, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_input_filename, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tape_motor, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_disk_write_enable, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_disk_write_back, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_cmp_fs, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_cmp_fsc, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_cmp_system, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_monochrome, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_cmp_colour_killer, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_ccr, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_picture, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_ntsc_scaling, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_tv_input, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_fullscreen, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_vdg_inverse, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_keymap, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_hkbd_layout, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_hkbd_lang, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_kbd_translate, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_joystick_port, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_print_destination, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_ratelimit_latch, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));
	ui_messenger_join_group(uimac->msgr_client_id, ui_tag_config_autosave, MESSENGER_NOTIFY_DELEGATE(cocoa_ui_state_notify, uimac));

	cocoa_update_machine_menu(uisdl2);
	cocoa_update_cartridge_menu(uisdl2);
	cocoa_update_joystick_menus(uisdl2);

	if (!sdl_vo_init(uisdl2)) {
		free(uisdl2);
		return NULL;
	}

	cocoa_check_coco_roms();

	return uisdl2;
}

static void ui_cocoa_free(void *sptr) {
	struct ui_macosx_interface *uimac = sptr;
	messenger_client_unregister(uimac->msgr_client_id);
}

static void cocoa_update_machine_menu(void *sptr) {
	(void)sptr;
}

static void cocoa_update_cartridge_menu(void *sptr) {
	struct ui_macosx_interface *uimac = sptr;
	(void)uimac;

	// Get list of cart configs
	struct slist *ccl = NULL;
	struct cart *cart = NULL;
	if (xroar.machine) {
		const struct machine_partdb_entry *mpe = (const struct machine_partdb_entry *)xroar.machine->part.partdb;
		const char *cart_arch = mpe->cart_arch;
		ccl = cart_config_list_is_a(cart_arch);
		cart = (struct cart *)part_component_by_id(&xroar.machine->part, "cart");
	}

	// Remove old entries
	while ([cartridge_menu numberOfItems] > 0) {
		[cartridge_menu removeItem:[cartridge_menu itemAtIndex:0]];
	}

	// Add entries
	NSMenuItem *item;
	NSString *tmp = [NSString stringWithFormat:@"Run cartridge ROM%C", 0x2026];
	item = [[NSMenuItem alloc] initWithTitle:tmp action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_action, ui_action_cart_insert)];
	[cartridge_menu addItem:item];
	[item release];

	[cartridge_menu addItem:[NSMenuItem separatorItem]];

	item = [[NSMenuItem alloc] initWithTitle:@"None" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(ui_tag_cartridge, 0)];
	[item setOnStateImage:[NSImage imageNamed:@"NSMenuRadio"]];
	[cartridge_menu addItem:item];
	[item release];
	for (struct slist *iter = ccl; iter; iter = iter->next) {
		struct cart_config *cc = iter->data;
		NSString *description = [[NSString alloc] initWithUTF8String:cc->description];
		item = [[NSMenuItem alloc] initWithTitle:description action:@selector(do_set_state:) keyEquivalent:@""];
		[item setTag:UIMAC_TAGV(ui_tag_cartridge, cc->id)];
		[item setOnStateImage:[NSImage imageNamed:@"NSMenuRadio"]];
		[description release];
		[cartridge_menu addItem:item];
		[item release];
	}

	// Free everything
	slist_free(ccl);
}

static void cocoa_update_joystick_menus(void *sptr) {
	struct ui_macosx_interface *uimac = sptr;
	(void)uimac;

	// Get list of joystick configs
	struct slist *jcl = joystick_config_list();

	// Remove old entries
	while ([joy_right_menu numberOfItems] > 0) {
		[joy_right_menu removeItem:[joy_right_menu itemAtIndex:0]];
	}
	while ([joy_left_menu numberOfItems] > 0) {
		[joy_left_menu removeItem:[joy_left_menu itemAtIndex:0]];
	}

	// Add entries
	NSMenuItem *item;

	item = [[NSMenuItem alloc] initWithTitle:@"None" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(uimac_tag_joystick_right, 0)];
	[joy_right_menu insertItem:item atIndex:0];
	[item release];

	item = [[NSMenuItem alloc] initWithTitle:@"None" action:@selector(do_set_state:) keyEquivalent:@""];
	[item setTag:UIMAC_TAGV(uimac_tag_joystick_left, 0)];
	[joy_left_menu insertItem:item atIndex:0];
	[item release];

	for (struct slist *iter = jcl; iter; iter = iter->next) {
		struct joystick_config *jc = iter->data;
		NSString *description = [[NSString alloc] initWithUTF8String:jc->description];
		item = [[NSMenuItem alloc] initWithTitle:description action:@selector(do_set_state:) keyEquivalent:@""];
		[item setTag:UIMAC_TAGV(uimac_tag_joystick_right, jc->id)];
		[item setOnStateImage:[NSImage imageNamed:@"NSMenuRadio"]];
		[joy_right_menu addItem:item];
		[item release];

		item = [[NSMenuItem alloc] initWithTitle:description action:@selector(do_set_state:) keyEquivalent:@""];
		[item setTag:UIMAC_TAGV(uimac_tag_joystick_left, jc->id)];
		[item setOnStateImage:[NSImage imageNamed:@"NSMenuRadio"]];
		[description release];
		[joy_left_menu addItem:item];
		[item release];
	}
}

static void cocoa_ui_state_notify(void *sptr, int tag, void *smsg) {
	struct ui_macosx_interface *uimac = sptr;
	struct ui_state_message *uimsg = smsg;
	int value = uimsg->value;
	const void *data = uimsg->data;

	switch (tag) {

	// Configuration

	case ui_tag_config_autosave:
		uimac->config.autosave = value;
		break;

	// Hardware

	case ui_tag_machine:
		uimac->machine.id = value;
		break;

	case ui_tag_cartridge:
		uimac->cart.id = value;
		break;

	// Cassettes

	case ui_tag_tape_input_filename:
		if (data) {
			[[kmsCoCoTapeDeckController sharedController] insertTape:(const char *)data];
		}
		break;

	case ui_tag_tape_motor:
		[[kmsCoCoTapeDeckController sharedController] updateStatus];
		break;

	case ui_tag_tape_flag_fast:
		uimac->tape.fast = value;
		break;

	case ui_tag_tape_flag_pad_auto:
		uimac->tape.pad_auto = value;
		break;

	case ui_tag_tape_flag_rewrite:
		uimac->tape.rewrite = value;
		break;

	case ui_tag_tape_playing:
		uimac->tape.playing = value;
		[[kmsCoCoTapeDeckController sharedController] updateStatus];
		break;

	// Disk

	case ui_tag_disk_write_enable:
		{
			int drive = (intptr_t)data;
			if (drive >= 0 && drive <= 3) {
				uimac->disk.drive[drive].write_enable = value;
			}
		}
		break;

	case ui_tag_disk_write_back:
		{
			int drive = (intptr_t)data;
			if (drive >= 0 && drive <= 3) {
				uimac->disk.drive[drive].write_back = value;
			}
		}
		break;

	// Video

	case ui_tag_cmp_fs:
		uimac->vo.cmp_fs = value;
		break;

	case ui_tag_cmp_fsc:
		uimac->vo.cmp_fsc = value;
		break;

	case ui_tag_cmp_system:
		uimac->vo.cmp_system = value;
		break;

	case ui_tag_monochrome:
		uimac->vo.monochrome = value;
		break;

	case ui_tag_cmp_colour_killer:
		uimac->vo.cmp_colour_killer = value;
		break;

	case ui_tag_ccr:
		uimac->vo.ccr = value;
		break;

	case ui_tag_picture:
		uimac->vo.picture = value;
		break;

	case ui_tag_ntsc_scaling:
		uimac->vo.ntsc_scaling = value;
		break;

	case ui_tag_tv_input:
		uimac->vo.tv_input = value;
		break;

	case ui_tag_fullscreen:
		uimac->vo.fullscreen = value;
		break;

	case ui_tag_vdg_inverse:
		uimac->vo.invert_text = value;
		break;

	// Keyboard

	case ui_tag_keymap:
		uimac->machine.keymap = value;
		break;

	case ui_tag_hkbd_layout:
		uimac->kbd.layout = value;
		break;

	case ui_tag_hkbd_lang:
		uimac->kbd.lang = value;
		break;

	case ui_tag_kbd_translate:
		uimac->kbd.translate = value;
		break;

	// Joysticks

	case ui_tag_joystick_port:
		if (value >= 0 && value <= 1) {
			uimac->joy.id[value] = (intptr_t)data;
		}
		break;

	// Printer

	case ui_tag_print_destination:
		uimac->lp.destination = value;
		break;

	// Debugging, misc

	case ui_tag_ratelimit_latch:
		uimac->misc.ratelimit_latch = value;
		break;

	default:
		break;
	}
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

static void cocoa_update_radio_menu_from_enum(NSMenu *menu, struct xconfig_enum *xc_enum,
					      unsigned tag) {
	// Remove old entries
	while ([menu numberOfItems] > 0) {
		[menu removeItem:[menu itemAtIndex:0]];
	}

	// Fine list terminating entry
	int enum_index;
	for (enum_index = 0; xc_enum[enum_index].name; enum_index++);

	// Add entries in reverse order
	while (enum_index > 0) {
		--enum_index;
		if (!xc_enum[enum_index].description) {
			continue;
		}
		NSString *description = [[NSString alloc] initWithUTF8String:xc_enum[enum_index].description];
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:description action:@selector(do_set_state:) keyEquivalent:@""];
		[item setTag:UIMAC_TAGV(tag, xc_enum[enum_index].value)];
		[item setOnStateImage:[NSImage imageNamed:@"NSMenuRadio"]];
		[menu insertItem:item atIndex:0];
		[item release];
		[description release];
	}
}

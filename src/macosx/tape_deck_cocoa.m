/* kmsCoCo Retro-Analog Tape Deck Cocoa UI
 *
 * Copyright 2026 kmsCoCo contributors
 * License: GNU GPL version 3 or later
 */

#import "tape_deck_cocoa.h"

#include "tape_deck.h"
#include "tape.h"
#include "ui.h"
#include "xroar.h"

extern int cocoa_super_all_keys;

static void apply_tape_directory_hint(NSSavePanel *panel) {
	const char *hint = xroar_get_tape_path();
	if (hint && *hint) {
		NSString *hp = [[NSString stringWithUTF8String:hint] stringByExpandingTildeInPath];
		BOOL isDir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:hp isDirectory:&isDir] && isDir) {
			[panel setDirectoryURL:[NSURL fileURLWithPath:hp isDirectory:YES]];
		}
	}
}

// Custom view that draws the ribbed speaker grille of the CTR-66
@interface kmsCoCoSpeakerGrilleView : NSView
@end

@implementation kmsCoCoSpeakerGrilleView

- (void)drawRect:(NSRect)dirtyRect {
	(void)dirtyRect;
	NSRect bounds = [self bounds];

	// Background: dark matte charcoal plastic
	[[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setFill];
	NSRectFill(bounds);

	// Draw horizontal ribbed slats
	CGFloat slatHeight = 4.0;
	CGFloat gap = 3.0;
	CGFloat step = slatHeight + gap;

	for (CGFloat y = bounds.origin.y + 4.0; y < bounds.origin.y + bounds.size.height - 4.0; y += step) {
		NSRect slatRect = NSMakeRect(bounds.origin.x + 8.0, y, bounds.size.width - 16.0, slatHeight);
		// Shadow
		[[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setFill];
		NSRectFill(NSMakeRect(slatRect.origin.x, slatRect.origin.y, slatRect.size.width, 1.5));
		// Highlight
		[[NSColor colorWithCalibratedWhite:0.32 alpha:1.0] setFill];
		NSRectFill(NSMakeRect(slatRect.origin.x, slatRect.origin.y + 1.5, slatRect.size.width, 2.5));
	}

	// Bezel border
	[[NSColor colorWithCalibratedWhite:0.10 alpha:1.0] setStroke];
	[NSBezierPath strokeRect:bounds];
}

@end

// Custom view for the cassette window frame
@interface kmsCoCoCassetteWellView : NSView
@end

@implementation kmsCoCoCassetteWellView

- (void)drawRect:(NSRect)dirtyRect {
	(void)dirtyRect;
	NSRect bounds = [self bounds];

	// Dark smoke-tinted recessed cassette well
	[[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
	NSRectFill(bounds);

	// Inset shadow / border
	[[NSColor colorWithCalibratedWhite:0.06 alpha:1.0] setStroke];
	[NSBezierPath setDefaultLineWidth:1.5];
	[NSBezierPath strokeRect:NSInsetRect(bounds, 0.75, 0.75)];
}

@end

// Custom table view supporting keyboard Delete/Backspace
@interface kmsCoCoTableView : NSTableView
@end

@implementation kmsCoCoTableView
- (void)keyDown:(NSEvent *)event {
	NSString *chars = [event charactersIgnoringModifiers];
	if ([chars length] > 0) {
		unichar c = [chars characterAtIndex:0];
		if (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == 0x7f) {
			if ([self delegate] && [[self delegate] respondsToSelector:@selector(pressErase:)]) {
				[[self delegate] performSelector:@selector(pressErase:) withObject:self];
				return;
			}
		}
	}
	[super keyDown:event];
}
@end

@interface kmsCoCoTapeDeckController () <NSMenuDelegate> {
	NSWindow *deckWindow;
	NSTextField *tapeTitleLabel;
	NSTextField *tapeTimeLabel;
	NSTextField *counterField;
	NSTextField *statusLabel;
	NSTextField *motorLed;

	NSButton *speakerButton;
	NSButton *speedButton;
	NSTextField *speakerSubLabel;

	NSButton *recButton;
	NSButton *playButton;
	NSButton *rewButton;
	NSButton *ffwdButton;
	NSButton *stopEjectButton;
	NSButton *newTapeButton;
	NSButton *eraseButton;

	NSTableView *segmentTable;
	NSScrollView *tableScrollView;

	NSTimer *refreshTimer;
	struct tape_deck_status currentStatus;
}
@end

@implementation kmsCoCoTapeDeckController

+ (kmsCoCoTapeDeckController *)sharedController {
	static kmsCoCoTapeDeckController *shared = nil;
	if (!shared) {
		shared = [[kmsCoCoTapeDeckController alloc] init];
	}
	return shared;
}

- (id)init {
	self = [super init];
	if (self) {
		tape_deck_init();
		[self buildWindow];
	}
	return self;
}

- (void)dealloc {
	if (refreshTimer) {
		[refreshTimer invalidate];
		refreshTimer = nil;
	}
	tape_deck_free();
	[deckWindow release];
	[super dealloc];
}

- (void)buildWindow {
	NSRect frame = NSMakeRect(200, 150, 460, 580);
	deckWindow = [[NSWindow alloc] initWithContentRect:frame
	                                         styleMask:(NSWindowStyleMaskTitled |
	                                                    NSWindowStyleMaskClosable |
	                                                    NSWindowStyleMaskMiniaturizable)
	                                           backing:NSBackingStoreBuffered
	                                             defer:NO];
	[deckWindow setTitle:@"Retro Cassette Deck"];
	[deckWindow setDelegate:self];
	[deckWindow setReleasedWhenClosed:NO];
	[[deckWindow contentView] setWantsLayer:YES];
	[[deckWindow contentView] layer].backgroundColor = [[NSColor colorWithCalibratedWhite:0.16 alpha:1.0] CGColor];

	NSView *content = [deckWindow contentView];

	// 1. TOP SECTION: SPEAKER GRILLE & TRANSPORT CONTROLS
	kmsCoCoSpeakerGrilleView *grille = [[kmsCoCoSpeakerGrilleView alloc] initWithFrame:NSMakeRect(14, 474, 432, 92)];
	[content addSubview:grille];

	// Speed (Left) & Speaker (Right) Buttons in grille
	speedButton = [[NSButton alloc] initWithFrame:NSMakeRect(16, 38, 196, 30)];
	[speedButton setButtonType:NSButtonTypeMomentaryPushIn];
	[speedButton setBezelStyle:NSBezelStyleRounded];
	[speedButton setTarget:self];
	[speedButton setAction:@selector(toggleTapeSpeed:)];
	[speedButton setFont:[NSFont boldSystemFontOfSize:11]];
	[grille addSubview:speedButton];

	speakerButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 38, 196, 30)];
	[speakerButton setButtonType:NSButtonTypeMomentaryPushIn];
	[speakerButton setBezelStyle:NSBezelStyleRounded];
	[speakerButton setTarget:self];
	[speakerButton setAction:@selector(toggleAudioMonitor:)];
	[speakerButton setFont:[NSFont boldSystemFontOfSize:11]];
	[grille addSubview:speakerButton];

	speakerSubLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 10, 404, 18)];
	[speakerSubLabel setBezeled:NO];
	[speakerSubLabel setDrawsBackground:NO];
	[speakerSubLabel setEditable:NO];
	[speakerSubLabel setSelectable:NO];
	[speakerSubLabel setAlignment:NSTextAlignmentCenter];
	[speakerSubLabel setTextColor:[NSColor colorWithCalibratedRed:0.4 green:1.0 blue:0.4 alpha:1.0]];
	[speakerSubLabel setFont:[NSFont systemFontOfSize:10]];
	[speakerSubLabel setStringValue:@""];
	[grille addSubview:speakerSubLabel];
	[grille release];

	// 2. MIDDLE SECTION: CASSETTE DOOR / WELL & SEGMENT INDEX
	kmsCoCoCassetteWellView *well = [[kmsCoCoCassetteWellView alloc] initWithFrame:NSMakeRect(14, 150, 432, 314)];
	[content addSubview:well];

	// Cassette Header Bar
	tapeTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 280, 250, 22)];
	[tapeTitleLabel setBezeled:NO];
	[tapeTitleLabel setDrawsBackground:NO];
	[tapeTitleLabel setEditable:NO];
	[tapeTitleLabel setSelectable:NO];
	[tapeTitleLabel setFont:[NSFont boldSystemFontOfSize:12]];
	[tapeTitleLabel setTextColor:[NSColor colorWithCalibratedRed:1.0 green:0.85 blue:0.4 alpha:1.0]];
	[tapeTitleLabel setStringValue:@"[ NO TAPE INSERTED ]"];
	[well addSubview:tapeTitleLabel];

	// Counter & Reset
	NSTextField *counterTag = [[NSTextField alloc] initWithFrame:NSMakeRect(268, 280, 52, 20)];
	[counterTag setBezeled:NO];
	[counterTag setDrawsBackground:NO];
	[counterTag setEditable:NO];
	[counterTag setSelectable:NO];
	[counterTag setFont:[NSFont systemFontOfSize:11]];
	[counterTag setTextColor:[NSColor colorWithCalibratedWhite:0.75 alpha:1.0]];
	[counterTag setStringValue:@"Counter:"];
	[well addSubview:counterTag];
	[counterTag release];

	counterField = [[NSTextField alloc] initWithFrame:NSMakeRect(322, 279, 44, 22)];
	[counterField setBezeled:YES];
	[counterField setBezelStyle:NSTextFieldSquareBezel];
	[counterField setDrawsBackground:YES];
	[counterField setBackgroundColor:[NSColor blackColor]];
	[counterField setTextColor:[NSColor colorWithCalibratedRed:0.2 green:1.0 blue:0.4 alpha:1.0]];
	[counterField setFont:[NSFont fontWithName:@"Courier-Bold" size:13] ? [NSFont fontWithName:@"Courier-Bold" size:13] : [NSFont userFixedPitchFontOfSize:13]];
	[counterField setAlignment:NSTextAlignmentCenter];
	[counterField setEditable:NO];
	[counterField setSelectable:NO];
	[counterField setStringValue:@"000"];
	[well addSubview:counterField];

	NSButton *resetBtn = [[NSButton alloc] initWithFrame:NSMakeRect(370, 277, 50, 24)];
	[resetBtn setTitle:@"000"];
	[resetBtn setBezelStyle:NSBezelStyleInline];
	[resetBtn setTarget:self];
	[resetBtn setAction:@selector(resetCounter:)];
	[resetBtn setFont:[NSFont systemFontOfSize:10]];
	[well addSubview:resetBtn];
	[resetBtn release];

	// Time position
	tapeTimeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 258, 240, 16)];
	[tapeTimeLabel setBezeled:NO];
	[tapeTimeLabel setDrawsBackground:NO];
	[tapeTimeLabel setEditable:NO];
	[tapeTimeLabel setSelectable:NO];
	[tapeTimeLabel setFont:[NSFont systemFontOfSize:10]];
	[tapeTimeLabel setTextColor:[NSColor colorWithCalibratedWhite:0.65 alpha:1.0]];
	[tapeTimeLabel setStringValue:@"Time: 00:00 / 00:00"];
	[well addSubview:tapeTimeLabel];

	// Table View for Segment Index
	NSRect tableRect = NSMakeRect(10, 10, 412, 242);
	tableScrollView = [[NSScrollView alloc] initWithFrame:tableRect];
	[tableScrollView setHasVerticalScroller:YES];
	[tableScrollView setBorderType:NSBezelBorder];

	segmentTable = [[kmsCoCoTableView alloc] initWithFrame:[[tableScrollView contentView] frame]];
	[segmentTable setAllowsColumnReordering:NO];
	[segmentTable setAllowsMultipleSelection:NO];
	[segmentTable setUsesAlternatingRowBackgroundColors:YES];
	[segmentTable setRowHeight:20];
	[segmentTable setGridStyleMask:(NSTableViewSolidHorizontalGridLineMask)];
	[segmentTable setDoubleAction:@selector(tableDoubleClicked:)];
	[segmentTable setTarget:self];
	[segmentTable setAction:@selector(tableClicked:)];

	// Right-click contextual menu
	NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Tape Context Menu"];
	[contextMenu setDelegate:(id<NSMenuDelegate>)self];

	NSMenuItem *itemPlay = [contextMenu addItemWithTitle:@"Play / Cue Recording"
	                                              action:@selector(contextPlay:)
	                                       keyEquivalent:@""];
	[itemPlay setTarget:self];

	NSMenuItem *itemRec = [contextMenu addItemWithTitle:@"Record / Overwrite Here…"
	                                             action:@selector(contextRecord:)
	                                      keyEquivalent:@""];
	[itemRec setTarget:self];

	[contextMenu addItem:[NSMenuItem separatorItem]];

	NSMenuItem *itemErase = [contextMenu addItemWithTitle:@"Delete Recording…"
	                                               action:@selector(pressErase:)
	                                        keyEquivalent:@""];
	[itemErase setTarget:self];

	[segmentTable setMenu:contextMenu];
	[contextMenu release];

	// Columns
	NSTableColumn *colIdx = [[NSTableColumn alloc] initWithIdentifier:@"idx"];
	[[colIdx headerCell] setStringValue:@"#"];
	[colIdx setWidth:24];
	[segmentTable addTableColumn:colIdx];
	[colIdx release];

	NSTableColumn *colName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	[[colName headerCell] setStringValue:@"Program Name"];
	[colName setWidth:140];
	[segmentTable addTableColumn:colName];
	[colName release];

	NSTableColumn *colType = [[NSTableColumn alloc] initWithIdentifier:@"type"];
	[[colType headerCell] setStringValue:@"Type"];
	[colType setWidth:65];
	[segmentTable addTableColumn:colType];
	[colType release];

	NSTableColumn *colTime = [[NSTableColumn alloc] initWithIdentifier:@"time"];
	[[colTime headerCell] setStringValue:@"Time"];
	[colTime setWidth:110];
	[segmentTable addTableColumn:colTime];
	[colTime release];

	NSTableColumn *colStatus = [[NSTableColumn alloc] initWithIdentifier:@"status"];
	[[colStatus headerCell] setStringValue:@"Status"];
	[colStatus setWidth:60];
	[segmentTable addTableColumn:colStatus];
	[colStatus release];

	[segmentTable setDataSource:self];
	[segmentTable setDelegate:self];
	[tableScrollView setDocumentView:segmentTable];
	[well addSubview:tableScrollView];
	[well release];

	// 3. BOTTOM SECTION: PIANO-KEY CONTROLS (CTR-66 Chunky Buttons)
	// RECORD (Red Stripe)
	recButton = [[NSButton alloc] initWithFrame:NSMakeRect(14, 88, 76, 52)];
	[recButton setButtonType:NSButtonTypeMomentaryPushIn];
	[recButton setBezelStyle:NSBezelStyleRegularSquare];
	[recButton setTitle:@"[|] REC"];
	[recButton setFont:[NSFont boldSystemFontOfSize:11]];
	[recButton setTarget:self];
	[recButton setAction:@selector(pressRecord:)];
	[content addSubview:recButton];

	// PLAY
	playButton = [[NSButton alloc] initWithFrame:NSMakeRect(96, 88, 76, 52)];
	[playButton setButtonType:NSButtonTypeMomentaryPushIn];
	[playButton setBezelStyle:NSBezelStyleRegularSquare];
	[playButton setTitle:@"▶ PLAY"];
	[playButton setFont:[NSFont boldSystemFontOfSize:11]];
	[playButton setTarget:self];
	[playButton setAction:@selector(pressPlay:)];
	[content addSubview:playButton];

	// REWIND
	rewButton = [[NSButton alloc] initWithFrame:NSMakeRect(178, 88, 76, 52)];
	[rewButton setButtonType:NSButtonTypeMomentaryPushIn];
	[rewButton setBezelStyle:NSBezelStyleRegularSquare];
	[rewButton setTitle:@"◄◄ REW"];
	[rewButton setFont:[NSFont boldSystemFontOfSize:11]];
	[rewButton setTarget:self];
	[rewButton setAction:@selector(pressRewind:)];
	[content addSubview:rewButton];

	// FAST-FORWARD
	ffwdButton = [[NSButton alloc] initWithFrame:NSMakeRect(260, 88, 76, 52)];
	[ffwdButton setButtonType:NSButtonTypeMomentaryPushIn];
	[ffwdButton setBezelStyle:NSBezelStyleRegularSquare];
	[ffwdButton setTitle:@"►► FF"];
	[ffwdButton setFont:[NSFont boldSystemFontOfSize:11]];
	[ffwdButton setTarget:self];
	[ffwdButton setAction:@selector(pressFfwd:)];
	[content addSubview:ffwdButton];

	// STOP / EJECT
	stopEjectButton = [[NSButton alloc] initWithFrame:NSMakeRect(342, 88, 104, 52)];
	[stopEjectButton setButtonType:NSButtonTypeMomentaryPushIn];
	[stopEjectButton setBezelStyle:NSBezelStyleRegularSquare];
	[stopEjectButton setTitle:@"■ ⏏ STOP/EJECT"];
	[stopEjectButton setFont:[NSFont boldSystemFontOfSize:10]];
	[stopEjectButton setTarget:self];
	[stopEjectButton setAction:@selector(pressStopEject:)];
	[content addSubview:stopEjectButton];

	// 4. BOTTOM STATUS BAR
	motorLed = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 48, 20, 20)];
	[motorLed setBezeled:NO];
	[motorLed setDrawsBackground:NO];
	[motorLed setEditable:NO];
	[motorLed setSelectable:NO];
	[motorLed setFont:[NSFont boldSystemFontOfSize:14]];
	[motorLed setStringValue:@"○"];
	[content addSubview:motorLed];

	statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(36, 48, 410, 20)];
	[statusLabel setBezeled:NO];
	[statusLabel setDrawsBackground:NO];
	[statusLabel setEditable:NO];
	[statusLabel setSelectable:NO];
	[statusLabel setFont:[NSFont systemFontOfSize:11]];
	[statusLabel setTextColor:[NSColor colorWithCalibratedWhite:0.85 alpha:1.0]];
	[statusLabel setStringValue:@"Insert a cassette to begin."];
	[content addSubview:statusLabel];

	// Quick New Tape Button
	newTapeButton = [[NSButton alloc] initWithFrame:NSMakeRect(14, 14, 155, 26)];
	[newTapeButton setTitle:@"New Blank Cassette…"];
	[newTapeButton setBezelStyle:NSBezelStyleRounded];
	[newTapeButton setFont:[NSFont systemFontOfSize:11]];
	[newTapeButton setTarget:self];
	[newTapeButton setAction:@selector(pressNewTape:)];
	[content addSubview:newTapeButton];

	// Erase Recording Button
	eraseButton = [[NSButton alloc] initWithFrame:NSMakeRect(176, 14, 145, 26)];
	[eraseButton setTitle:@"Erase Recording…"];
	[eraseButton setBezelStyle:NSBezelStyleRounded];
	[eraseButton setFont:[NSFont systemFontOfSize:11]];
	[eraseButton setTarget:self];
	[eraseButton setAction:@selector(pressErase:)];
	[content addSubview:eraseButton];

	[self updateStatus];
}

- (void)showTapeDeckWindow {
	[deckWindow center];
	[deckWindow makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];

	if (!refreshTimer) {
		refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
		                                                target:self
		                                              selector:@selector(tick:)
		                                              userInfo:nil
		                                               repeats:YES];
	}
	[self updateStatus];
}

- (void)windowWillClose:(NSNotification *)notification {
	(void)notification;
	if (refreshTimer) {
		[refreshTimer invalidate];
		refreshTimer = nil;
	}
}

- (void)insertTape:(const char *)path {
	if (path && *path) {
		tape_deck_insert_file(path);
		[self updateStatus];
	}
}

- (void)tick:(NSTimer *)timer {
	(void)timer;
	[self updateStatus];
}

- (void)updateStatus {
	tape_deck_get_status(&currentStatus);

	// Audio monitor & speed states
	if (currentStatus.fast_speed) {
		[speedButton setTitle:@"⚡ Turbo Speed"];
		[speakerButton setEnabled:NO];
		[speakerButton setTitle:@"🔇 Sound: OFF"];
		[speakerSubLabel setStringValue:@""];
	} else {
		[speedButton setTitle:@"⏱ Authentic Speed"];
		[speakerButton setEnabled:YES];
		if (currentStatus.audio_monitor) {
			[speakerButton setTitle:@"🔊 Sound: ON"];
			[speakerSubLabel setTextColor:[NSColor colorWithCalibratedRed:0.4 green:1.0 blue:0.4 alpha:1.0]];
			[speakerSubLabel setStringValue:@"Sound ON: streaming 1500 baud 'screaming robot' audio during CLOAD."];
		} else {
			[speakerButton setTitle:@"🔇 Sound: OFF"];
			[speakerSubLabel setStringValue:@""];
		}
	}

	// Tape header & counter
	if (currentStatus.has_tape) {
		const char *cap = (currentStatus.capacity_type == TAPE_CAPACITY_C30) ? "C-30 (12 slots)" :
		                  ((currentStatus.capacity_type == TAPE_CAPACITY_C60) ? "C-60 (20 slots)" : "C-15 (6 slots)");
		[tapeTitleLabel setStringValue:[NSString stringWithFormat:@"Tape: %@ [%s]",
		                                [NSString stringWithUTF8String:currentStatus.display_title], cap]];
		[counterField setStringValue:[NSString stringWithFormat:@"%03d", currentStatus.counter % 1000]];

		int curSec = currentStatus.current_ms / 1000;
		int totSec = currentStatus.total_ms / 1000;
		[tapeTimeLabel setStringValue:[NSString stringWithFormat:@"Time: %02d:%02d / %02d:%02d (%d segments)",
		                               curSec / 60, curSec % 60, totSec / 60, totSec % 60, currentStatus.num_segments]];
	} else {
		[tapeTitleLabel setStringValue:@"[ NO TAPE INSERTED ]"];
		[counterField setStringValue:@"000"];
		[tapeTimeLabel setStringValue:@"Time: 00:00 / 00:00"];
	}

	// Button latch states
	if (currentStatus.is_recording) {
		[recButton setTitle:@"● REC [ON]"];
		[playButton setTitle:@"▶ PLAY"];
	} else if (currentStatus.is_playing) {
		[recButton setTitle:@"[|] REC"];
		[playButton setTitle:@"▶ PLAY [ON]"];
	} else {
		[recButton setTitle:@"[|] REC"];
		[playButton setTitle:@"▶ PLAY"];
	}

	// Motor status LED & text
	if (currentStatus.motor_on) {
		if (currentStatus.is_recording) {
			[motorLed setStringValue:@"●"];
			[motorLed setTextColor:[NSColor colorWithCalibratedRed:1.0 green:0.2 blue:0.2 alpha:1.0]];
			[statusLabel setStringValue:@"MOTOR ENGAGED: Saving data to cassette..."];
		} else {
			[motorLed setStringValue:@"●"];
			[motorLed setTextColor:[NSColor colorWithCalibratedRed:0.2 green:1.0 blue:0.4 alpha:1.0]];
			[statusLabel setStringValue:@"MOTOR ENGAGED: Playing / loading from cassette..."];
		}
	} else {
		[motorLed setStringValue:@"○"];
		[motorLed setTextColor:[NSColor colorWithCalibratedWhite:0.5 alpha:1.0]];
		if (currentStatus.is_recording) {
			[statusLabel setStringValue:@"RECORD ARMED: Waiting for CoCo motor relay (CSAVE)"];
		} else if (currentStatus.is_playing) {
			[statusLabel setStringValue:@"PLAY ARMED: Waiting for CoCo motor relay (CLOAD)"];
		} else if (currentStatus.has_tape) {
			[statusLabel setStringValue:@"Tape Stopped. Ready for CLOAD or CSAVE."];
		} else {
			[statusLabel setStringValue:@"Cassette door open. Load a tape to begin."];
		}
	}

	NSInteger selRow = [segmentTable selectedRow];
	bool canErase = currentStatus.has_tape && (selRow >= 0 && selRow < currentStatus.num_segments);
	[eraseButton setEnabled:canErase];

	[segmentTable reloadData];
	if (currentStatus.motor_on || [segmentTable selectedRow] < 0) {
		if (currentStatus.current_index >= 0 && currentStatus.current_index < currentStatus.num_segments) {
			[segmentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:currentStatus.current_index] byExtendingSelection:NO];
		} else if (currentStatus.current_index == currentStatus.num_segments && currentStatus.num_segments < currentStatus.max_slots) {
			[segmentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:currentStatus.current_index] byExtendingSelection:NO];
		}
	}
}

// Actions
- (void)toggleAudioMonitor:(id)sender {
	(void)sender;
	bool current = tape_deck_get_audio_monitor();
	tape_deck_set_audio_monitor(!current);
	[self updateStatus];
}

- (void)toggleTapeSpeed:(id)sender {
	(void)sender;
	bool cur = tape_deck_get_fast_speed();
	tape_deck_set_fast_speed(!cur);
	if (!cur) {
		tape_deck_set_audio_monitor(false);
	}
	[self updateStatus];
}

- (void)insertTapeAction:(id)sender {
	(void)sender;
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setTitle:@"Insert Cassette Tape"];
	[panel setPrompt:@"Insert"];
	[panel setCanChooseFiles:YES];
	[panel setCanChooseDirectories:NO];
	[panel setAllowsMultipleSelection:NO];
	[panel setAllowedFileTypes:@[@"cas", @"k7", @"wav", @"c10"]];
	apply_tape_directory_hint(panel);

	cocoa_super_all_keys = 1;
	NSModalResponse resp = [panel runModal];
	cocoa_super_all_keys = 0;

	if (resp == NSModalResponseOK) {
		NSURL *url = [panel URL];
		if (url && [url isFileURL]) {
			tape_deck_insert_file([[url path] UTF8String]);
			[self updateStatus];
			[self showTapeDeckWindow];
		}
	}
}

- (void)newTapeAction:(id)sender {
	[self pressNewTape:sender];
	[self showTapeDeckWindow];
}

- (void)ejectTapeAction:(id)sender {
	(void)sender;
	tape_deck_eject();
	[self updateStatus];
}

- (void)resetCounter:(id)sender {
	(void)sender;
	tape_deck_reset_counter();
	[self updateStatus];
}

- (void)pressPlay:(id)sender {
	(void)sender;
	if (!currentStatus.has_tape) {
		[self pressStopEject:nil];
		return;
	}
	tape_deck_play();
	[self updateStatus];
}

- (void)pressRecord:(id)sender {
	(void)sender;
	if (!currentStatus.has_tape) {
		[self pressStopEject:nil];
		return;
	}

	if (currentStatus.is_recording) {
		// Clicking RECORD while armed cancels / disarms
		tape_deck_stop();
		[self updateStatus];
		return;
	}

	NSInteger selRow = [segmentTable selectedRow];
	if (selRow < 0) {
		selRow = currentStatus.current_index;
	}

	if (selRow >= 0 && selRow < currentStatus.num_segments) {
		// Existing slot selected: Prompt Overwrite vs Insert
		struct tape_deck_segment *seg = &currentStatus.segments[selRow];
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText:[NSString stringWithFormat:@"Record into Slot %d", (int)selRow + 1]];
		[alert setInformativeText:[NSString stringWithFormat:@"Slot %d already contains \"%s\".\n\nDo you want to Overwrite this slot, or Insert the new recording (shifting \"%s\" and subsequent recordings down)?", (int)selRow + 1, seg->name, seg->name]];
		[alert addButtonWithTitle:@"Overwrite"];
		[alert addButtonWithTitle:@"Insert (Shift Down)"];
		[alert addButtonWithTitle:@"Cancel"];

		cocoa_super_all_keys = 1;
		NSModalResponse resp = [alert runModal];
		cocoa_super_all_keys = 0;
		[alert release];

		if (resp == NSAlertFirstButtonReturn) {
			// Overwrite
			tape_deck_seek_index((int)selRow);
			tape_deck_record_mode(true);
		} else if (resp == NSAlertSecondButtonReturn) {
			// Insert / Shift Down
			tape_deck_seek_index((int)selRow);
			tape_deck_record_mode(false);
		} else {
			// Cancel
			return;
		}
	} else {
		// Empty slot or append at end
		if (selRow >= currentStatus.num_segments) {
			tape_deck_seek_index(currentStatus.num_segments);
		}
		if (!tape_deck_record_mode(false)) {
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:@"Cassette Full"];
			[alert setInformativeText:@"This cassette has reached its maximum recording slot capacity. Eject and insert another tape."];
			[alert addButtonWithTitle:@"OK"];
			cocoa_super_all_keys = 1;
			[alert runModal];
			cocoa_super_all_keys = 0;
			[alert release];
		}
	}
	[self updateStatus];
}

- (void)pressErase:(id)sender {
	(void)sender;
	if (!currentStatus.has_tape || currentStatus.num_segments == 0) return;
	NSInteger selRow = [segmentTable selectedRow];
	if (selRow < 0 || selRow >= currentStatus.num_segments) {
		selRow = currentStatus.current_index;
	}
	if (selRow < 0 || selRow >= currentStatus.num_segments) return;

	struct tape_deck_segment *seg = &currentStatus.segments[selRow];

	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:@"Delete Recording?"];
	[alert setInformativeText:[NSString stringWithFormat:@"Are you sure you want to delete Slot %d (\"%s\") from this cassette?\n\nThis will permanently remove the program from the tape and shift any subsequent recordings up.", (int)selRow + 1, seg->name]];
	[alert addButtonWithTitle:@"Delete"];
	[alert addButtonWithTitle:@"Cancel"];

	cocoa_super_all_keys = 1;
	NSModalResponse resp = [alert runModal];
	cocoa_super_all_keys = 0;
	[alert release];

	if (resp == NSAlertFirstButtonReturn) {
		tape_deck_delete_segment((int)selRow);
		[self updateStatus];
	}
}

- (void)pressRewind:(id)sender {
	(void)sender;
	tape_deck_rewind_step();
	[self updateStatus];
}

- (void)pressFfwd:(id)sender {
	(void)sender;
	tape_deck_ffwd_step();
	[self updateStatus];
}

- (void)pressStopEject:(id)sender {
	(void)sender;
	if (currentStatus.is_playing || currentStatus.is_recording) {
		// Stop transport
		tape_deck_stop();
		[self updateStatus];
		return;
	}

	// Already stopped: Eject tape and offer to open another
	tape_deck_eject();
	[self updateStatus];

	NSOpenPanel *panel = [NSOpenPanel openPanel];
	[panel setTitle:@"Insert Cassette Tape"];
	[panel setPrompt:@"Insert"];
	[panel setCanChooseFiles:YES];
	[panel setCanChooseDirectories:NO];
	[panel setAllowsMultipleSelection:NO];
	[panel setAllowedFileTypes:@[@"cas", @"k7", @"wav", @"c10"]];
	apply_tape_directory_hint(panel);

	cocoa_super_all_keys = 1;
	NSModalResponse resp = [panel runModal];
	cocoa_super_all_keys = 0;

	if (resp == NSModalResponseOK) {
		NSURL *url = [panel URL];
		if (url && [url isFileURL]) {
			tape_deck_insert_file([[url path] UTF8String]);
		}
	}
	[self updateStatus];
}

- (void)pressNewTape:(id)sender {
	(void)sender;
	NSSavePanel *panel = [NSSavePanel savePanel];
	[panel setTitle:@"Create New Cassette Tape"];
	[panel setPrompt:@"Create"];
	[panel setAllowedFileTypes:@[@"cas"]];
	[panel setNameFieldStringValue:@"NewTape.cas"];
	apply_tape_directory_hint(panel);

	// Capacity popup accessory view
	NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 32)];
	NSTextField *lbl = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 6, 90, 18)];
	[lbl setStringValue:@"Tape Length:"];
	[lbl setBezeled:NO];
	[lbl setDrawsBackground:NO];
	[lbl setEditable:NO];
	[lbl setSelectable:NO];
	[acc addSubview:lbl];
	[lbl release];

	NSPopUpButton *capPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(96, 4, 190, 24) pullsDown:NO];
	[capPop addItemWithTitle:@"C-15 (15 min / 6 slots)"];
	[[capPop lastItem] setTag:TAPE_CAPACITY_C15];
	[capPop addItemWithTitle:@"C-30 (30 min / 12 slots)"];
	[[capPop lastItem] setTag:TAPE_CAPACITY_C30];
	[capPop addItemWithTitle:@"C-60 (60 min / 20 slots)"];
	[[capPop lastItem] setTag:TAPE_CAPACITY_C60];
	[acc addSubview:capPop];

	[panel setAccessoryView:acc];
	[acc release];

	cocoa_super_all_keys = 1;
	NSModalResponse resp = [panel runModal];
	cocoa_super_all_keys = 0;

	if (resp == NSModalResponseOK) {
		NSURL *url = [panel URL];
		if (url && [url isFileURL]) {
			int cap = (int)[[capPop selectedItem] tag];
			tape_deck_create_new([[url path] UTF8String], cap);
		}
	}
	[capPop release];
	[self updateStatus];
}

- (void)tableClicked:(id)sender {
	(void)sender;
	NSInteger row = [segmentTable clickedRow];
	if (row >= 0) {
		if (row < currentStatus.num_segments) {
			tape_deck_seek_index((int)row);
		} else {
			tape_deck_seek_index(currentStatus.num_segments);
		}
		[self updateStatus];
	}
}

- (void)tableDoubleClicked:(id)sender {
	(void)sender;
	NSInteger row = [segmentTable clickedRow];
	if (row >= 0 && row < currentStatus.num_segments) {
		tape_deck_seek_index((int)row);
		[self pressPlay:nil];
	}
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
	NSInteger clicked = [segmentTable clickedRow];
	if (clicked >= 0) {
		[segmentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:clicked] byExtendingSelection:NO];
	}
	NSInteger sel = [segmentTable selectedRow];
	bool hasTape = currentStatus.has_tape;
	bool isSeg = hasTape && (sel >= 0 && sel < currentStatus.num_segments);
	bool isEmpty = hasTape && (sel >= currentStatus.num_segments && sel < currentStatus.max_slots);

	for (NSMenuItem *item in [menu itemArray]) {
		if ([item action] == @selector(contextPlay:)) {
			[item setEnabled:isSeg];
		} else if ([item action] == @selector(contextRecord:)) {
			[item setEnabled:(isSeg || isEmpty)];
			if (isSeg) {
				[item setTitle:@"Record / Overwrite Here…"];
			} else {
				[item setTitle:@"Record Here"];
			}
		} else if ([item action] == @selector(pressErase:)) {
			[item setEnabled:isSeg];
		}
	}
}

- (void)contextPlay:(id)sender {
	(void)sender;
	NSInteger row = [segmentTable selectedRow];
	if (row >= 0 && row < currentStatus.num_segments) {
		tape_deck_seek_index((int)row);
		[self pressPlay:nil];
	}
}

- (void)contextRecord:(id)sender {
	(void)sender;
	[self pressRecord:nil];
}

// Table Data Source & Delegate
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	(void)tableView;
	if (!currentStatus.has_tape) return 0;
	// Show existing segments plus remaining empty slots up to max_slots
	int total = currentStatus.num_segments;
	if (total < currentStatus.max_slots) {
		total++; // show next available slot
	}
	return total;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	(void)tableView;
	NSString *ident = [tableColumn identifier];

	if (row < currentStatus.num_segments) {
		struct tape_deck_segment *seg = &currentStatus.segments[row];
		if ([ident isEqualToString:@"idx"]) {
			return [NSString stringWithFormat:@"%d", (int)row + 1];
		} else if ([ident isEqualToString:@"name"]) {
			return [NSString stringWithFormat:@"\"%s\"", seg->name];
		} else if ([ident isEqualToString:@"type"]) {
			if (seg->type == 0) return @"BASIC";
			if (seg->type == 1) return @"DATA";
			if (seg->type == 2) return @"ML (BIN)";
			return @"Unknown";
		} else if ([ident isEqualToString:@"time"]) {
			int sSec = seg->start_ms / 1000;
			int eSec = seg->end_ms / 1000;
			return [NSString stringWithFormat:@"%02d:%02d - %02d:%02d",
			        sSec / 60, sSec % 60, eSec / 60, eSec % 60];
		} else if ([ident isEqualToString:@"status"]) {
			if (row == currentStatus.current_index) {
				return currentStatus.motor_on ? @"Active ▶" : @"Cued ◀";
			}
			return @"Ready";
		}
	} else {
		// Empty slot
		if ([ident isEqualToString:@"idx"]) {
			return [NSString stringWithFormat:@"%d", (int)row + 1];
		} else if ([ident isEqualToString:@"name"]) {
			return @"[ Empty Slot ]";
		} else if ([ident isEqualToString:@"type"]) {
			return @"--";
		} else if ([ident isEqualToString:@"time"]) {
			return @"--";
		} else if ([ident isEqualToString:@"status"]) {
			if (row == currentStatus.current_index) {
				return @"Cued (End)";
			}
			return @"--";
		}
	}
	return @"";
}

@end

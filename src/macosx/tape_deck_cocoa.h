/* kmsCoCo Retro-Analog Tape Deck Cocoa UI
 *
 * Copyright 2026 kmsCoCo contributors
 * License: GNU GPL version 3 or later
 */

#ifndef KMSCOCO_TAPE_DECK_COCOA_H_
#define KMSCOCO_TAPE_DECK_COCOA_H_

#import <Cocoa/Cocoa.h>

@interface kmsCoCoTapeDeckController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
+ (kmsCoCoTapeDeckController *)sharedController;
- (void)showTapeDeckWindow;
- (void)updateStatus;
- (void)insertTape:(const char *)path;

- (void)insertTapeAction:(id)sender;
- (void)newTapeAction:(id)sender;
- (void)ejectTapeAction:(id)sender;
@end

#endif

#import <Foundation/Foundation.h>

/// Hands memory back to the system when iOS says it is running short.
///
/// iOS warns an app before it starts killing things. Minecraft's heap is by far the
/// largest thing in this process, and G1's ordinary collections only touch a small
/// slice of it - the rest of the garbage sits there until a full compaction runs,
/// which normally does not happen until the heap is already full. By then the graphics
/// driver has usually failed to allocate and taken the process down with it.
///
/// Asking for that full compaction the moment iOS complains turns a crash into a
/// stutter. In practice a compaction on a large modpack hands back 150-400 MB.
@interface MemoryPressureRelief : NSObject

/// Begin listening for memory warnings. Safe to call more than once; only the first
/// call does anything.
+ (void)start;

/// Run a relief pass now, if one is not already running and enough time has passed
/// since the last one. Returns immediately - the work happens on a background thread.
+ (void)relieveNow;

@end

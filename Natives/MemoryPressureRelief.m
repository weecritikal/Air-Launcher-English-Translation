#import <UIKit/UIKit.h>
#import "MemoryPressureRelief.h"
#import "environ.h"

// How long to wait between relief passes while compaction is still paying off.
// A compaction on a big modpack stops the world for roughly a second, so running
// one every few seconds would be its own kind of unplayable.
static const NSTimeInterval kMinimumIntervalSeconds = 6.0;

// How long to wait once compaction has stopped paying off. If a full pass barely
// reclaims anything, the heap is genuinely full of live objects and repeating the
// pass only adds stutter to a game that is already in trouble.
static const NSTimeInterval kBackoffIntervalSeconds = 45.0;

// Below this fraction of the heap reclaimed, a pass counts as not worth repeating.
static const double kWorthwhileReclaimFraction = 0.03;

@implementation MemoryPressureRelief

+ (dispatch_queue_t)queue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("net.kdt.pojavlaunch.memory-relief", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            [MemoryPressureRelief relieveNow];
        }];
        NSLog(@"[MemoryRelief] Listening for memory warnings");
    });
}

+ (void)relieveNow {
    // The queue below is serial, so these are only ever read and written by one block
    // at a time and need no locking of their own.
    static NSTimeInterval lastRunAt = 0;
    static NSTimeInterval nextAllowedGap = kMinimumIntervalSeconds;

    if (!runtimeJavaVMPtr) return;

    // iOS can send several warnings in a burst. Queueing them is fine - each one that
    // arrives too soon after the last pass costs a time comparison and nothing else.
    dispatch_async(self.queue, ^{
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (lastRunAt > 0 && (now - lastRunAt) < nextAllowedGap) {
            return;
        }
        lastRunAt = now;

        long long reclaimed = 0, maxHeap = 0;
        if ([self runFullCollectionReclaimed:&reclaimed maxHeap:&maxHeap] && maxHeap > 0) {
            double fraction = (double)reclaimed / (double)maxHeap;
            nextAllowedGap = (fraction < kWorthwhileReclaimFraction)
                ? kBackoffIntervalSeconds : kMinimumIntervalSeconds;
        }
    });
}

/// Ask the JVM for a full collection and report what it handed back.
///
/// Runs on the relief queue, never on the render thread. The thread is attached as a
/// daemon so an attach that outlives the game cannot hold JVM shutdown open.
+ (BOOL)runFullCollectionReclaimed:(long long *)outReclaimed maxHeap:(long long *)outMaxHeap {
    JavaVM *vm = runtimeJavaVMPtr;
    if (!vm) return NO;

    JNIEnv *env = NULL;
    BOOL attachedHere = NO;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4);
    if (status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, &env, NULL) != JNI_OK || env == NULL) {
            return NO;
        }
        attachedHere = YES;
    } else if (status != JNI_OK || env == NULL) {
        return NO;
    }

    BOOL succeeded = NO;

    // Every reference below is local to this frame, so popping it releases them all
    // even on an early return.
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass runtimeClass = (*env)->FindClass(env, "java/lang/Runtime");
        jmethodID getRuntime = runtimeClass ? (*env)->GetStaticMethodID(env, runtimeClass, "getRuntime", "()Ljava/lang/Runtime;") : NULL;
        jmethodID totalMemory = runtimeClass ? (*env)->GetMethodID(env, runtimeClass, "totalMemory", "()J") : NULL;
        jmethodID freeMemory = runtimeClass ? (*env)->GetMethodID(env, runtimeClass, "freeMemory", "()J") : NULL;
        jmethodID maxMemory = runtimeClass ? (*env)->GetMethodID(env, runtimeClass, "maxMemory", "()J") : NULL;
        jmethodID gc = runtimeClass ? (*env)->GetMethodID(env, runtimeClass, "gc", "()V") : NULL;

        jobject runtime = (getRuntime != NULL) ? (*env)->CallStaticObjectMethod(env, runtimeClass, getRuntime) : NULL;

        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            runtime = NULL;
        }

        if (runtime != NULL && totalMemory && freeMemory && maxMemory && gc) {
            long long usedBefore = (long long)((*env)->CallLongMethod(env, runtime, totalMemory) -
                                               (*env)->CallLongMethod(env, runtime, freeMemory));
            long long limit = (long long)(*env)->CallLongMethod(env, runtime, maxMemory);

            (*env)->CallVoidMethod(env, runtime, gc);
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
            } else {
                long long usedAfter = (long long)((*env)->CallLongMethod(env, runtime, totalMemory) -
                                                  (*env)->CallLongMethod(env, runtime, freeMemory));
                long long reclaimed = usedBefore - usedAfter;
                if (reclaimed < 0) reclaimed = 0;

                NSLog(@"[MemoryRelief] iOS reported memory pressure. Java heap %lld MB -> %lld MB of %lld MB (handed back %lld MB)",
                      usedBefore >> 20, usedAfter >> 20, limit >> 20, reclaimed >> 20);

                if (outReclaimed) *outReclaimed = reclaimed;
                if (outMaxHeap) *outMaxHeap = limit;
                succeeded = YES;
            }
        }

        (*env)->PopLocalFrame(env, NULL);
    }

    if (attachedHere) {
        (*vm)->DetachCurrentThread(vm);
    }
    return succeeded;
}

@end

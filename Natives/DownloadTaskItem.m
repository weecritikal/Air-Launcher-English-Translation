//
//  DownloadTaskItem.m
//  Amethyst
//

#import "DownloadTaskItem.h"

@implementation DownloadTaskItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _taskId = [[NSUUID UUID] UUIDString];
        _createdAt = [NSDate date];
        _state = DownloadTaskStatePending;
        _progress = -1.0;
        _totalBytes = -1;
        _downloadedBytes = 0;
        _speed = 0;
        _estimatedTimeRemaining = 0;
    }
    return self;
}

- (BOOL)isActive {
    return self.state == DownloadTaskStatePending || self.state == DownloadTaskStateDownloading;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<DownloadTaskItem id=%@ name=%@ type=%ld state=%ld progress=%.2f>",
            self.taskId, self.displayName, (long)self.resourceType, (long)self.state, self.progress];
}

@end

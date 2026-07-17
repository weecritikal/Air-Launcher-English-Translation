#import "DownloadTaskItem.h"

NSString * const DownloadTaskResourceTypeMinecraft    = @"minecraft";
NSString * const DownloadTaskResourceTypeModloader    = @"modloader";
NSString * const DownloadTaskResourceTypeMod          = @"mod";
NSString * const DownloadTaskResourceTypeShader       = @"shader";
NSString * const DownloadTaskResourceTypeResourcePack = @"resourcepack";
NSString * const DownloadTaskResourceTypeDataPack     = @"datapack";
NSString * const DownloadTaskResourceTypeModpack      = @"modpack";
NSString * const DownloadTaskResourceTypeWorld        = @"world";

@implementation DownloadTaskItem

- (instancetype)initWithResourceType:(NSString *)resourceType
                        resourceName:(NSString *)resourceName
                         displayName:(NSString *)displayName
                      downloadSource:(NSString *)downloadSource
                             rawTask:(id)rawTask
                      supportsResume:(BOOL)supportsResume
                             iconURL:(NSString *)iconURL {
    self = [super init];
    if (self) {
        _taskId = [[NSUUID UUID] UUIDString];
        _resourceType = [resourceType copy] ?: @"";
        _resourceName = [resourceName copy] ?: @"";
        _displayName = [displayName copy] ?: _resourceName;
        _downloadSource = [downloadSource copy] ?: @"official";
        _state = DownloadTaskStatePending;
        _progress = -1.0;
        _totalSize = -1;
        _downloadedSize = 0;
        _speed = 0.0;
        _estimatedTimeRemaining = 0.0;
        _iconURL = [iconURL copy];
        _supportsResume = supportsResume;
        _createdDate = [NSDate date];
        _rawTask = rawTask;
        _errorInfo = nil;
        _userInfo = [NSMutableDictionary dictionary];
        _retryCount = 0;
        _maxRetryCount = 3;
    }
    return self;
}

@end

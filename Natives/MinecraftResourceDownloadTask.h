#import <UIKit/UIKit.h>

@class AFURLSessionManager;
@class ModpackAPI;

extern NSString * const kMinecraftResourceDownloadBackgroundSessionIdentifier;

@interface MinecraftResourceDownloadTask : NSObject

+ (AFURLSessionManager *)sharedBackgroundSessionManager;

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, copy) void(^modpackDownloadCompletion)(void);

// 重试相关属性
@property(nonatomic) NSInteger maxRetryCount;
@property(nonatomic, readonly) NSInteger currentRetryCount;
@property(nonatomic, copy) void(^retryCallback)(NSInteger retryCount, NSInteger maxRetryCount);

// 阶段5修复（参照 FCL）：失败的文件列表，单文件下载失败不再取消整批任务，
// 而是记录到此数组，最终汇总报告给用户。每个元素是 @{@"name": ..., "error": ...}
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *failedFiles;

// 新增方法声明（用于账户检查）
- (BOOL)checkAccessWithDialog:(BOOL)show;

- (void)prepareForDownload;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success;

// 带重试的下载任务创建
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path retryCount:(NSInteger)retryCount success:(void (^)())success;

- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end
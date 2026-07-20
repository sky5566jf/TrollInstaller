#import <Foundation/Foundation.h>

@interface HTTPServer : NSObject
+ (instancetype)sharedServer;
- (int)port;
/// 启动监听。若端口已被占用（守护进程已在跑）则返回 NO，App 可安全忽略。
- (BOOL)start:(NSError **)error;
/// 便捷启动：失败仅打日志，不抛异常。
- (void)start;
@end

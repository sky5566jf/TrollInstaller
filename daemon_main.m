#import <Foundation/Foundation.h>
#import "HTTPServer.h"

// 常驻守护进程：由 launchd 以 root 拉起，与 App 是否在前台/被划掉无关。
// 监听 0.0.0.0:8588，收到 /install?url= 后通过 LSApplicationWorkspace 触发巨魔安装。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        NSLog(@"[trollserver] daemon launching");

        HTTPServer *srv = [HTTPServer sharedServer];
        NSError *err = nil;
        if (![srv start:&err]) {
            NSLog(@"[trollserver] start failed: %@", err);
            return 1;
        }
        NSLog(@"[trollserver] listening on :%d", srv.port);

        // 常驻：事件由工作线程处理，主线程跑 RunLoop 防止退出
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}

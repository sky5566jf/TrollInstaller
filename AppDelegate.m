#import "AppDelegate.h"
#import "ViewController.h"
#import "HTTPServer.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 自启动：App 一进前台即尝试拉起 HTTP 服务（若守护进程已占用端口则自动跳过）
    [[HTTPServer sharedServer] start];

    // 首次启动尝试安装常驻守护进程（需 root，依赖二进制 setuid 位）
    [self installDaemonIfNeeded];

    return YES;
}

/// 把 LaunchDaemon 装进 /Library/LaunchDaemons，使服务在 App 被划掉/重启后依然常驻。
/// 需要 root：TrollStore 把 App 安装为 root:wheel 并保留 setuid 位，App 启动时 setuid(0) 提权。
- (void)installDaemonIfNeeded {
    NSString *dest = @"/Library/LaunchDaemons/com.matisu.trollserver.plist";
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:dest]) {
        // 已安装：确保正在运行（重启后 launchd 会自动拉起，这里只是保险）
        system("launchctl start com.matisu.trollserver 2>/dev/null");
        return;
    }

    // 尝试提权到 root
    if (setuid(0) != 0 || setgid(0) != 0) {
        NSLog(@"[install] 无法获取 root 权限，常驻守护进程未安装（仅前台服务模式可用）");
        return;
    }

    NSString *src = [[NSBundle mainBundle] pathForResource:@"com.matisu.trollserver" ofType:@"plist"];
    if (!src) { NSLog(@"[install] 守护进程 plist 缺失"); return; }

    NSError *e = nil;
    [fm removeItemAtPath:dest error:nil];
    if (![fm copyItemAtPath:src toPath:dest error:&e]) {
        NSLog(@"[install] 拷贝 plist 失败: %@", e);
        return;
    }
    chown([dest UTF8String], 0, 0);
    chmod([dest UTF8String], 0644);

    // 加载守护进程（兼容新旧 launchctl；失败不致命）
    system("launchctl load /Library/LaunchDaemons/com.matisu.trollserver.plist 2>/dev/null");
    system("launchctl bootstrap system /Library/LaunchDaemons/com.matisu.trollserver.plist 2>/dev/null");
    system("launchctl start com.matisu.trollserver 2>/dev/null");
    NSLog(@"[install] 常驻守护进程已安装并启动");
}

@end

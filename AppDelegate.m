#import "AppDelegate.h"
#import "ViewController.h"
#import "HTTPServer.h"
#import <sys/stat.h>
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>

/// iOS 上 system() 被标记为 unavailable，用 posix_spawn 直接拉起 /usr/bin/launchctl。
/// 所有 launchctl 调用都走这里，不依赖 shell。
static void runLaunchctl(NSArray<NSString *> *args) {
    pid_t pid = 0;
    NSMutableArray *argvM = [NSMutableArray arrayWithObject:@"/usr/bin/launchctl"];
    [argvM addObjectsFromArray:args];
    NSUInteger n = argvM.count;
    char **cargv = (char **)calloc(n + 1, sizeof(char *));
    for (NSUInteger i = 0; i < n; i++) cargv[i] = (char *)[argvM[i] UTF8String];
    extern char **environ;
    int rc = posix_spawn(&pid, "/usr/bin/launchctl", NULL, NULL, cargv, environ);
    free(cargv);
    if (rc == 0) {
        int status = 0;
        waitpid(pid, &status, 0);
    } else {
        NSLog(@"[install] posix_spawn launchctl failed: %s", strerror(rc));
    }
}

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 自启动：App 一进前台即起 HTTP 服务（守护进程已占用端口时 HTTPServer 内部会跳过）
    [[HTTPServer sharedServer] start];

    // best-effort 安装常驻守护进程（需 root + 可写 LaunchDaemons 目录）
    [self installDaemonIfNeeded];

    return YES;
}

/// 尝试把 LaunchDaemon 装进系统 LaunchDaemons 目录，使服务在 App 被划掉/重启后仍常驻。
/// 依次尝试 rootful（/Library/LaunchDaemons）与 rootless（/var/jb/Library/LaunchDaemons）路径。
/// 任一可写即装；都不可写（非越狱/只读根分区）则降级为纯前台服务模式，不崩不卡。
- (void)installDaemonIfNeeded {
    NSArray *candidates = @[
        @"/Library/LaunchDaemons/com.matisu.trollserver.plist",
        @"/var/jb/Library/LaunchDaemons/com.matisu.trollserver.plist",
    ];

    // 1) 已安装：确保在跑（重启后 launchd 会自动拉起，这里只是保险）
    for (NSString *dest in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
            runLaunchctl(@[@"start", @"com.matisu.trollserver"]);
            NSLog(@"[install] 守护进程已存在: %@", dest);
            return;
        }
    }

    // 2) 尝试提权到 root
    BOOL gotRoot = (setuid(0) == 0 && setgid(0) == 0);
    if (!gotRoot) {
        NSLog(@"[install] 无 root 权限 → 仅前台服务模式（守护进程未安装）");
        return;
    }

    NSString *src = [[NSBundle mainBundle] pathForResource:@"com.matisu.trollserver" ofType:@"plist"];
    if (!src) { NSLog(@"[install] 守护进程 plist 缺失"); return; }

    // 3) 依次尝试候选路径，首个可写的就用
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *installedPath = nil;
    for (NSString *dest in candidates) {
        // 确保父目录存在
        NSString *parent = [dest stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:dest error:nil];
        NSError *e = nil;
        if ([fm copyItemAtPath:src toPath:dest error:&e]) {
            chown([dest UTF8String], 0, 0);
            chmod([dest UTF8String], 0644);
            installedPath = dest;
            break;
        } else {
            NSLog(@"[install] 写入失败，跳过: %@ (%@)", dest, e.localizedDescription);
        }
    }
    if (!installedPath) {
        NSLog(@"[install] 所有 LaunchDaemons 路径均不可写（非越狱/根分区只读）→ 仅前台服务模式");
        return;
    }

    // 4) 加载并启动（兼容新旧 launchctl 子命令，失败不致命）
    runLaunchctl(@[@"load", installedPath]);
    runLaunchctl(@[@"bootstrap", @"system", installedPath]);
    runLaunchctl(@[@"start", @"com.matisu.trollserver"]);
    NSLog(@"[install] 常驻守护进程已安装并启动: %@", installedPath);
}

@end

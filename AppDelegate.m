#import "AppDelegate.h"
#import "ViewController.h"
#import "HTTPServer.h"
#import <AVFoundation/AVFoundation.h>
#import <sys/stat.h>
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>

/// iOS 上 system() 被标记为 unavailable，用 posix_spawn 直接拉起 /usr/bin/launchctl。
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

@interface AppDelegate ()
@property (nonatomic, strong) AVAudioPlayer *silencePlayer;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 后台音频保活：播放静音音频让进程退后台不被 iOS 挂起，API 继续响应。
    // mixWithOthers 不打断其他 App 的音乐播放。
    [self setupBackgroundKeepAlive];

    // 自启动：App 一进前台即起 HTTP 服务（守护进程已占用端口时 HTTPServer 内部会跳过）
    [[HTTPServer sharedServer] start];

    // best-effort 安装常驻守护进程（需 root + 可写 LaunchDaemons 目录）
    // 纯 TrollStore 非越狱：setuid(0) 失败 → 自动降级为前台服务模式，不崩不卡。
    [self installDaemonIfNeeded];

    return YES;
}

#pragma mark - 后台音频保活

- (void)setupBackgroundKeepAlive {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // playback 类别 + mixWithOthers：声明后台音频权限，但不打断别人的音乐
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) NSLog(@"[bg] session category error: %@", err);
    [session setActive:YES error:&err];
    if (err) NSLog(@"[bg] session active error: %@", err);

    NSString *path = [[NSBundle mainBundle] pathForResource:@"silence" ofType:@"wav"];
    if (!path) {
        NSLog(@"[bg] silence.wav 不在 bundle 内，后台保活未生效");
        return;
    }
    self.silencePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!self.silencePlayer) {
        NSLog(@"[bg] player 初始化失败: %@", err);
        return;
    }
    self.silencePlayer.numberOfLoops = -1;  // 无限循环
    self.silencePlayer.volume = 0;           // 静音
    [self.silencePlayer prepareToPlay];
    // 启动即播放（静音），前台后台都不挂起进程
    if ([self.silencePlayer play]) {
        NSLog(@"[bg] 后台音频保活已启动（静音循环播放）");
    } else {
        NSLog(@"[bg] 静音播放启动失败");
    }
}

#pragma mark - 守护进程安装（越狱设备才生效，非越狱自动降级）

- (void)installDaemonIfNeeded {
    NSArray *candidates = @[
        @"/Library/LaunchDaemons/com.matisu.trollserver.plist",
        @"/var/jb/Library/LaunchDaemons/com.matisu.trollserver.plist",
    ];

    for (NSString *dest in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
            runLaunchctl(@[@"start", @"com.matisu.trollserver"]);
            NSLog(@"[install] 守护进程已存在: %@", dest);
            return;
        }
    }

    BOOL gotRoot = (setuid(0) == 0 && setgid(0) == 0);
    if (!gotRoot) {
        NSLog(@"[install] 无 root 权限 → 仅前台服务模式（守护进程未安装）");
        return;
    }

    NSString *src = [[NSBundle mainBundle] pathForResource:@"com.matisu.trollserver" ofType:@"plist"];
    if (!src) { NSLog(@"[install] 守护进程 plist 缺失"); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *installedPath = nil;
    for (NSString *dest in candidates) {
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
        NSLog(@"[install] 所有 LaunchDaemons 路径均不可写 → 仅前台服务模式");
        return;
    }

    runLaunchctl(@[@"load", installedPath]);
    runLaunchctl(@[@"bootstrap", @"system", installedPath]);
    runLaunchctl(@[@"start", @"com.matisu.trollserver"]);
    NSLog(@"[install] 常驻守护进程已安装并启动: %@", installedPath);
}

@end

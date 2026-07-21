//
//  MatisuHotspotManager.m
//  Matisu巨魔助手 — NEHotspotHelper 重启自启管理器
//
//  核心机制：
//  - NEHotspotHelper 是纯巨魔版（非越狱）唯一系统级冷启动唤醒源
//  - 设备重启后所有进程已死，只有系统 WiFi 关联事件能通过 HotspotHelper 注册把 App 拉起来
//  - App 被唤醒 → handleCommand → beginBackgroundTask → posix_spawn supervisor
//
//  参考：TrollVNC TVNCHotspotManager.m (F:\workbuddy\MatisuXCS苹果版\app\TrollVNC\TrollVNC\TVNCHotspotManager.m)
//  2026-07-22 用户实机验证：TrollVNC.app 巨魔版在 WiFi 连接时重启手机确实自动拉起服务
//

#import "MatisuHotspotManager.h"
#import <NetworkExtension/NetworkExtension.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>
#import <signal.h>

@interface MatisuHotspotManager ()
@property (nonatomic, assign) SCNetworkReachabilityRef reachability;
@property (nonatomic, assign) BOOL lastNetworkState;
@end

@implementation MatisuHotspotManager

+ (instancetype)sharedManager {
    static MatisuHotspotManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastNetworkState = NO;
        // App 切回前台时兜底确认 supervisor 在运行
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - NEHotspotHelper 注册

- (BOOL)registerWithName:(NSString *)name {
    // 注册 NEHotspotHelper：系统在 WiFi 关联/认证/保活时回调 handler
    // 这是重启后冷启动 App 的唯一机制（纯巨魔版非越狱）
    NSDictionary *options = @{kNEHotspotHelperOptionDisplayName: name};
    __weak typeof(self) weakSelf = self;
    BOOL result = [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];

    NSLog(@"[matisu] NEHotspotHelper registered: %d (name=%@)", result, name);

    // 同时启动 SCNetworkReachability 兜底监控
    [self startNetworkReachabilityMonitor];

    return result;
}

#pragma mark - NEHotspotHelper 命令处理

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    // 区分命令类型：Evaluate/Authenticate/Maintain 是 WiFi 关联类事件 → 拉起服务
    // FilterScanList/PresentUI/Logoff/None 仅应答不触发（避免高频事件重复拉起）
    BOOL shouldStartService = NO;

    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeEvaluate:
        case kNEHotspotHelperCommandTypeAuthenticate:
        case kNEHotspotHelperCommandTypeMaintain:
            // 系统正在评估/认证/保活某个 WiFi 网络 → 网络子系统已活跃，拉起服务
            NSLog(@"[matisu] HotspotHelper command: %ld (association class)", (long)command.commandType);
            shouldStartService = YES;
            break;
        case kNEHotspotHelperCommandTypeFilterScanList:
        case kNEHotspotHelperCommandTypePresentUI:
        case kNEHotspotHelperCommandTypeLogoff:
        case kNEHotspotHelperCommandTypeNone:
        default:
            // 扫描列表/UI/注销等高频或无关事件：不触发
            break;
    }

    if (shouldStartService) {
        [self ensureSupervisorRunning];
    }
    // 不显式应答：iOS26 SDK 中 createResponse:/executeWithResponse: 选择器已不存在，
    // helper 注册本身即可在 WiFi 变化时触发拉起，保持与 TrollVNC v4.21 一致的行为
}

#pragma mark - 拉起 Supervisor

- (void)ensureSupervisorRunning {
    // 使用 beginBackgroundTask 延长后台执行时间
    // iOS 15+ 上 NEHotspotHelper 唤醒 app 后，如果没有 background task，
    // 系统可能会在 supervisor 启动前就杀死 app
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];

    NSLog(@"[matisu] ensureSupervisorRunning: launching supervisor");
    [self launchSupervisor];

    // 2 秒后再次确认（给 supervisor 启动时间）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self launchSupervisor];
        if (bgTaskId != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTaskId];
            bgTaskId = UIBackgroundTaskInvalid;
        }
    });
}

/// posix_spawn 拉起常驻监督器二进制（与 App 同 bundle）
/// supervisor 会 setsid() 脱离 App 进程组，App 被划掉后 supervisor 继续存活
- (void)launchSupervisor {
    NSString *supPath = [[NSBundle mainBundle] pathForResource:@"matisusupervisor" ofType:nil];
    if (!supPath) {
        NSLog(@"[matisu] supervisor binary not found in bundle");
        return;
    }

    // 检查单例锁文件，避免重复 spawn
    // supervisor 自己有 flock 单例保护，这里只是减少不必要的 spawn 调用
    NSString *lockPath = @"/var/mobile/Library/Caches/com.matisu.trollassistant.supervisor.pid";
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:lockPath]) {
        // 锁文件存在，supervisor 可能在运行，检查进程
        NSString *pidStr = [NSString stringWithContentsOfFile:lockPath encoding:NSUTF8StringEncoding error:nil];
        if (pidStr) {
            NSInteger pid = [pidStr integerValue];
            if (pid > 0) {
                // kill(pid, 0) 不发送信号，只检查进程是否存在
                if (kill((pid_t)pid, 0) == 0) {
                    NSLog(@"[matisu] supervisor already running (pid=%ld), skip", (long)pid);
                    return;
                }
            }
        }
    }

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // 关闭 stdio，supervisor 独立后台运行
    posix_spawn_file_actions_addclose(&actions, STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    char *argv[] = { (char *)[supPath UTF8String], NULL };
    extern char **environ;

    int rc = posix_spawn(&pid, [supPath UTF8String], &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);

    if (rc == 0) {
        NSLog(@"[matisu] supervisor launched, pid=%d", pid);
    } else {
        NSLog(@"[matisu] posix_spawn supervisor failed: %s", strerror(rc));
    }
}

#pragma mark - SCNetworkReachability 兜底监控

- (void)startNetworkReachabilityMonitor {
    // 监听任意网络连接变化（WiFi/以太网/蜂窝）
    // 这修复了纯以太网连接不触发 NEHotspotHelper 的问题（但只在 App 进程存活时有效）
    struct sockaddr_in zeroAddress;
    memset(&zeroAddress, 0, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    self.reachability = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zeroAddress);

    if (self.reachability) {
        SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
        SCNetworkReachabilitySetCallback(self.reachability, MatisuReachabilityCallback, &context);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, dispatch_get_main_queue());

        // 检查初始状态
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.reachability, &flags)) {
            BOOL initialConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
            self.lastNetworkState = initialConnected;
            if (initialConnected) {
                NSLog(@"[matisu] Network: initial state = connected, ensuring supervisor");
                [self ensureSupervisorRunning];
            }
        }

        NSLog(@"[matisu] Network: reachability monitor started");
    }
}

static void MatisuReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    MatisuHotspotManager *manager = (__bridge MatisuHotspotManager *)info;

    BOOL isConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL wasConnected = manager.lastNetworkState;
    manager.lastNetworkState = isConnected;

    NSLog(@"[matisu] Network: reachability changed, connected=%d (was=%d)", isConnected, wasConnected);

    if (isConnected && !wasConnected) {
        // 网络从无到有（WiFi 或以太网）→ 补拉起
        NSLog(@"[matisu] Network: connection detected, triggering supervisor startup");
        [manager ensureSupervisorRunning];
    }
}

#pragma mark - 前台兜底

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"[matisu] App became active, ensuring supervisor running");
    [self ensureSupervisorRunning];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.reachability) {
        SCNetworkReachabilitySetCallback(self.reachability, NULL, NULL);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, NULL);
        CFRelease(self.reachability);
        self.reachability = NULL;
    }
}

@end

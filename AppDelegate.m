#import "AppDelegate.h"
#import "ViewController.h"
#import "MatisuHotspotManager.h"
#import <BackgroundTasks/BackgroundTasks.h>
#import <UserNotifications/UserNotifications.h>

// BGTaskScheduler 周期后台任务标识符
// 必须与 Info.plist 中 BGTaskSchedulerPermittedIdentifiers 一致
static NSString *const kMatisuBGTaskIdentifier = @"com.matisu.trollassistant.servicemonitor";

// 启动成功提示：本地通知唯一标识（仅同 App 内用于去重/替换，跨 App 不冲突）
static NSString *const kStartupNotificationID = @"com.matisu.trollassistant.startup";

// 服务就绪探测参数
static const NSTimeInterval kProbeInterval = 0.25;   // 轮询间隔（秒）
static const NSTimeInterval kProbeTimeout  = 10.0;   // 总超时（秒）：超时仍无服务则安静退出

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate {
    UIBackgroundTaskIdentifier _launchBgTask;
    dispatch_source_t _probeTimer;
    NSDate *_probeStart;
    BOOL _didExit;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 申请后台执行时间，确保服务有足够时间启动
    // iOS 15+ 上 NEHotspotHelper 冷启动唤醒 App 后，没有 background task 可能被系统秒杀
    _launchBgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:_launchBgTask];
        _launchBgTask = UIBackgroundTaskInvalid;
    }];

    // ── 通知中心代理：App 在前台时也允许弹横幅 ──
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionBadge | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (!granted) NSLog(@"[matisu] 通知权限未授予，启动提示可能不会显示");
    }];

    // ── 注册 NEHotspotHelper（重启自启核心）──
    // 纯巨魔版唯一系统级冷启动唤醒源：
    // 设备重启 → 系统连 WiFi → NEHotspotHelper 触发 → 系统冷启动 App → handler 拉起 supervisor
    [[MatisuHotspotManager sharedManager] registerWithName:@"M巨魔助手"];

    // ── 注册 BGTaskScheduler（周期后台任务兜底）──
    [self registerBackgroundTask];

    // ── 拉起常驻监督器(resident supervisor)──
    // supervisor 会 setsid() 脱离本进程，App 退出后继续存活，独力提供 8588 API 服务
    [[MatisuHotspotManager sharedManager] ensureSupervisorRunning];

    // ── 启动就绪探测：轮询 127.0.0.1:8588/status ──
    // 一旦 HTTP 服务真正监听并响应 200，即认为服务启动成功，弹本地通知后退出 App
    // 超时（默认 10s）仍未就绪则安静退出（服务可能本就仅靠 supervisor 运行）
    _didExit = NO;
    [self startServiceReadinessProbe];

    return YES;
}

#pragma mark - 服务就绪探测 + 启动提示

- (void)startServiceReadinessProbe {
    _probeStart = [NSDate date];
    dispatch_queue_t q = dispatch_queue_create("com.matisu.startup.probe", DISPATCH_QUEUE_SERIAL);
    _probeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_probeTimer,
                              DISPATCH_TIME_NOW,
                              (uint64_t)(kProbeInterval * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_probeTimer, ^{
        [weakSelf probeTick];
    });
    dispatch_resume(_probeTimer);
}

- (void)probeTick {
    if (_didExit) return;

    // 超时保护：超过 kProbeTimeout 仍无服务，安静退出（不弹通知）
    if ([[NSDate date] timeIntervalSinceDate:_probeStart] > kProbeTimeout) {
        [self stopProbe];
        [self finishBootstrap];
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8588/status"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                      cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                  timeoutInterval:2.0];
    [req setHTTPMethod:@"GET"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                         completionHandler:^(NSData * _Nullable data,
                                                                             NSURLResponse * _Nullable response,
                                                                             NSError * _Nullable error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (!error && http.statusCode == 200) {
            [self stopProbe];
            [self notifyStartupAndExit];
        }
        // 非 200 或出错则下一拍继续重试，直到超时
    }];
    [task resume];
}

- (void)stopProbe {
    if (_probeTimer) {
        dispatch_source_cancel(_probeTimer);
        _probeTimer = nil;
    }
}

- (void)notifyStartupAndExit {
    if (_didExit) return;
    _didExit = YES;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"巨魔助手启动成功";
    content.body = @"";

    // trigger=nil → 立即投递；通知由系统派发，App 退出后横幅仍正常显示
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:kStartupNotificationID
                                                                      content:content
                                                                      trigger:nil];

    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) NSLog(@"[matisu] 启动通知投递失败: %@", error);
        // 留出 1.5s 让系统把横幅呈现出来，再退出 App 进程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self finishBootstrap];
        });
    }];
}

#pragma mark - UNUserNotificationCenterDelegate

// App 在前台时也要能弹横幅（iOS 14+ 用 Banner 选项，最低部署即为 iOS 14 无需 else 分支）
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        willPresentNotification:(UNNotification *)notification
          withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner);
}

#pragma mark - Bootstrap 退出

/// 完成 bootstrap：结束后台任务并退出 App 进程（supervisor 继续存活）
- (void)finishBootstrap {
    [self stopProbe];
    if (_launchBgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_launchBgTask];
        _launchBgTask = UIBackgroundTaskInvalid;
    }
    NSLog(@"[matisu] bootstrap complete, exiting app process (supervisor continues running)");
    exit(0);
}

#pragma mark - BGTaskScheduler

- (void)registerBackgroundTask {
    BOOL registered = [[BGTaskScheduler sharedScheduler]
        registerForTaskWithIdentifier:kMatisuBGTaskIdentifier
                          usingQueue:nil
                       launchHandler:^void(BGTask *task) {
        [self handleBackgroundTask:task];
    }];
    if (registered) {
        [self scheduleNextBackgroundTask];
        NSLog(@"[matisu] BGTaskScheduler registered: %@", kMatisuBGTaskIdentifier);
    } else {
        NSLog(@"[matisu] BGTaskScheduler registration failed");
    }
}

- (void)scheduleNextBackgroundTask {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kMatisuBGTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:60]; // 最早 60 秒后
    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
    if (error) {
        NSLog(@"[matisu] BGTaskScheduler schedule error: %@", error);
    }
}

- (void)handleBackgroundTask:(BGTask *)task {
    // 安排下一次任务
    [self scheduleNextBackgroundTask];

    // 申请后台时间拉起 supervisor
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];

    [[MatisuHotspotManager sharedManager] ensureSupervisorRunning];

    // 延迟标记任务完成：ensureSupervisorRunning 内部有 2 秒 dispatch_after 二次确认，
    // 需等其完成后才标记 BGTask 完成，否则系统可能在二次确认前就收回后台时间
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [task setTaskCompletedWithSuccess:YES];

        if (bgTaskId != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTaskId];
            bgTaskId = UIBackgroundTaskInvalid;
        }
    });
}

@end

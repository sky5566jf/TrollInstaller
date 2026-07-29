#import "AppDelegate.h"
#import "ViewController.h"
#import "MatisuHotspotManager.h"
#import <BackgroundTasks/BackgroundTasks.h>
#import <UserNotifications/UserNotifications.h>

// BGTaskScheduler 周期后台任务标识符
// 必须与 Info.plist 中 BGTaskSchedulerPermittedIdentifiers 一致
static NSString *const kMatisuBGTaskIdentifier = @"com.matisu.trollassistant.servicemonitor";

// HTTP 服务端口（与 HTTPServer.m 中 TI_PORT 保持一致）
static const int kMatisuServicePort = 8588;

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate {
    UIBackgroundTaskIdentifier _launchBgTask;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 申请后台执行时间，确保服务有足够时间启动
    // iOS 15+ 上 NEHotspotHelper 冷启动唤醒 App 后，没有 background task 可能被系统秒杀
    _launchBgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:_launchBgTask];
        _launchBgTask = UIBackgroundTaskInvalid;
    }];

    // ── 注册 NEHotspotHelper（重启自启核心）──
    // 纯巨魔版唯一系统级冷启动唤醒源：
    // 设备重启 → 系统连 WiFi → NEHotspotHelper 触发 → 系统冷启动 App → handler 拉起 supervisor
    [[MatisuHotspotManager sharedManager] registerWithName:@"M巨魔助手"];

    // ── 注册 BGTaskScheduler（周期后台任务兜底）──
    [self registerBackgroundTask];

    // ── 准备启动成功通知 ──
    // 把通知中心代理设为自身，使 App 在前台时通知也能以横幅呈现
    // 首次运行会向用户申请通知权限（仅弹一次，仅用于本地横幅，无需远程推送）
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *err) {
        NSLog(@"[matisu] notification authorization granted=%d error=%@", granted, err);
    }];

    // ── 拉起常驻监督器(resident supervisor)──
    // supervisor 会 setsid() 脱离本进程，App 退出后继续存活，独力提供 8588 API 服务
    [[MatisuHotspotManager sharedManager] ensureSupervisorRunning];

    // ── 轮询 HTTP 服务，确认真正就绪后再弹「启动成功」提示 ──
    // 服务就绪 → 本地通知「M巨魔助手 启动成功」 → 退出 App（通知由系统派发，不依赖 App 存活）
    [self waitForServerThenNotify];

    return YES;
}

#pragma mark - 启动成功提示

/// 轮询本地 HTTP 服务，确认其真正监听并响应后，派发一条本地通知
/// 用后台串行定时器轮询，不阻塞主线程；超时（默认 10s）则安静退出，不弹通知
- (void)waitForServerThenNotify {
    dispatch_queue_t q = dispatch_queue_create("com.matisu.serverwait", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC,
                              100 * NSEC_PER_MSEC);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    __block BOOL resolved = NO;

    dispatch_source_set_event_handler(timer, ^{
        if (resolved) return;

        // 超时仍未就绪：安静退出（服务可能本就仅靠 supervisor 运行，App 无需停留）
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            resolved = YES;
            dispatch_source_cancel(timer);
            [self finishBootstrap];
            return;
        }

        // 探测服务是否真正响应 200
        if ([self probeServerReady]) {
            resolved = YES;
            dispatch_source_cancel(timer);
            [self showStartupNotification];
            // 给通知中心一点时间把请求入队，再退出 App
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self finishBootstrap];
            });
        }
    });

    dispatch_resume(timer);
}

/// 同步探测本地 HTTP 服务是否就绪（127.0.0.1:8588/status）
- (BOOL)probeServerReady {
    NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:%d/status", kMatisuServicePort];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:1.0];
    req.HTTPMethod = @"GET";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSError *err = nil;
    NSHTTPURLResponse *resp = nil;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
#pragma clang diagnostic pop

    return (resp && resp.statusCode == 200);
}

/// 派发「M巨魔助手 启动成功」本地通知
- (void)showStartupNotification {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"M巨魔助手";
    content.body  = @"启动成功，服务已就绪";

    UNNotificationRequest *req =
        [UNNotificationRequest requestWithIdentifier:@"com.matisu.trollassistant.startup"
                                             content:content
                                             trigger:nil];  // trigger=nil → 立即派发

    [center addNotificationRequest:req withCompletionHandler:^(NSError *err) {
        if (err) {
            NSLog(@"[matisu] startup notification failed: %@", err);
        } else {
            NSLog(@"[matisu] startup notification scheduled: M巨魔助手 启动成功");
        }
    }];
}

/// 前台也能以横幅显示通知（否则 App 在前台时通知只会静默进通知中心）
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // 最低部署版本为 iOS 14，横幅用 Banner（Alert 选项在 iOS 14 已弃用）
    completionHandler(UNNotificationPresentationOptionBanner);
}

/// 完成 bootstrap：结束后台任务并退出 App 进程（supervisor 继续存活）
- (void)finishBootstrap {
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

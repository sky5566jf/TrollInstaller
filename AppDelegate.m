#import "AppDelegate.h"
#import "ViewController.h"
#import "MatisuHotspotManager.h"
#import <BackgroundTasks/BackgroundTasks.h>

// BGTaskScheduler 周期后台任务标识符
// 必须与 Info.plist 中 BGTaskSchedulerPermittedIdentifiers 一致
static NSString *const kMatisuBGTaskIdentifier = @"com.matisu.trollassistant.servicemonitor";

// 服务就绪探测参数
static const NSTimeInterval kProbeInterval = 0.25;   // 轮询间隔（秒）
static const NSTimeInterval kProbeTimeout  = 10.0;   // 总超时（秒）：超时仍无服务则安静退出
static const NSTimeInterval kBannerDuration = 2.5;   // 启动横幅停留时长（秒），延长以便看清

// 轻量文件日志：远端设备难抓 syslog，写入 /tmp 便于 SSH 诊断（App 带 no-container 可写）
static void MatisuLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[matisu] %@", msg);
    NSString *path = @"/tmp/matisu_bootstrap.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@interface AppDelegate ()
@end

@implementation AppDelegate {
    UIBackgroundTaskIdentifier _launchBgTask;
    dispatch_source_t _probeTimer;
    NSDate *_probeStart;
    BOOL _didExit;
    UIWindow *_bannerWindow;   // 应用内启动提示横幅的窗口（强引用，避免被 ARC 释放）
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    MatisuLog(@"App launched");

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

    // ── 拉起常驻监督器(resident supervisor)──
    // supervisor 会 setsid() 脱离本进程，App 退出后继续存活，独力提供 8588 API 服务
    [[MatisuHotspotManager sharedManager] ensureSupervisorRunning];
    MatisuLog(@"supervisor launch requested");

    // ── 启动就绪探测：轮询 127.0.0.1:8588/status ──
    // 一旦 HTTP 服务真正监听并响应 200，即认为服务启动成功，显示应用内横幅后退出 App
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

    // 超时保护：超过 kProbeTimeout 仍无服务，安静退出（不弹提示）
    if ([[NSDate date] timeIntervalSinceDate:_probeStart] > kProbeTimeout) {
        MatisuLog(@"probe timeout, exit quietly");
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
            MatisuLog(@"status 200, service ready");
            [self stopProbe];
            // ⚠️ NSURLSession 回调默认在后台线程，UI 操作必须切回主线程，否则横幅不会显示
            dispatch_async(dispatch_get_main_queue(), ^{
                [self notifyStartupAndExit];
            });
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

    // 应用内瞬时提示：打开 App 后悬浮显示约 2.5s，无需任何通知权限，每次手动打开都必见
    MatisuLog(@"showing in-app banner");
    [self showInAppBanner:@"巨魔助手启动成功"];

    // 停留后退出 App 进程（supervisor 继续存活）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBannerDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self finishBootstrap];
    });
}

#pragma mark - 应用内启动提示横幅

/// 在 App 自身窗口上悬浮显示一条小横幅（无权限依赖，前台可见即显示）
- (void)showInAppBanner:(NSString *)text {
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window = window; // 设为 App 主窗口，确保系统正常合成显示（兜底非 scene 应用无主窗口的情况）
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = vc;
    [window makeKeyAndVisible];

    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    label.layer.cornerRadius = 14;
    label.clipsToBounds = YES;
    label.layoutMargins = UIEdgeInsetsMake(0, 18, 0, 18);
    [label setTranslatesAutoresizingMaskIntoConstraints:NO];
    [vc.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:12],
        [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:vc.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:vc.view.trailingAnchor constant:-24],
        [label.heightAnchor constraintEqualToConstant:44],
    ]];

    // 入场动画：轻微放大 + 淡入
    label.alpha = 0.0;
    label.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.25 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        label.alpha = 1.0;
        label.transform = CGAffineTransformIdentity;
    } completion:nil];

    // 强引用 window，避免 ARC 提前释放导致横幅闪退
    _bannerWindow = window;
}

#pragma mark - Bootstrap 退出

/// 完成 bootstrap：结束后台任务并退出 App 进程（supervisor 继续存活）
- (void)finishBootstrap {
    [self stopProbe];
    _bannerWindow = nil;
    self.window = nil; // 释放提示窗口
    if (_launchBgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_launchBgTask];
        _launchBgTask = UIBackgroundTaskInvalid;
    }
    MatisuLog(@"bootstrap complete, exiting app process (supervisor continues running)");
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
        MatisuLog(@"BGTaskScheduler registered");
    } else {
        MatisuLog(@"BGTaskScheduler registration failed");
    }
}

- (void)scheduleNextBackgroundTask {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kMatisuBGTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:60]; // 最早 60 秒后
    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
    if (error) {
        MatisuLog(@"BGTaskScheduler schedule error: %@", error);
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

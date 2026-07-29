#import "AppDelegate.h"
#import "ViewController.h"
#import "MatisuHotspotManager.h"
#import <BackgroundTasks/BackgroundTasks.h>

// BGTaskScheduler 周期后台任务标识符
// 必须与 Info.plist 中 BGTaskSchedulerPermittedIdentifiers 一致
static NSString *const kMatisuBGTaskIdentifier = @"com.matisu.trollassistant.servicemonitor";

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 申请后台执行时间，确保服务有足够时间启动
    // iOS 15+ 上 NEHotspotHelper 冷启动唤醒 App 后，没有 background task 可能被系统秒杀
    __block UIBackgroundTaskIdentifier launchBgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:launchBgTask];
        launchBgTask = UIBackgroundTaskInvalid;
    }];

    // ── 注册 NEHotspotHelper（重启自启核心）──
    // 纯巨魔版唯一系统级冷启动唤醒源：
    // 设备重启 → 系统连 WiFi → NEHotspotHelper 触发 → 系统冷启动 App → handler 拉起 supervisor
    [[MatisuHotspotManager sharedManager] registerWithName:@"Matisu巨魔助手"];

    // ── 注册 BGTaskScheduler（周期后台任务兜底）──
    [self registerBackgroundTask];

    // ── 拉起常驻监督器(resident supervisor)──
    // supervisor 会 setsid() 脱离本进程，App 退出后继续存活，独力提供 8588 API 服务
    [[MatisuHotspotManager sharedManager] ensureSupervisorRunning];

    // ── Bootstrap-only：本软件本质是 API 服务，UI 非必需 ──
    // 拉起 supervisor 后 App 进程主动退出，仅保留 ~3-6MB 的 supervisor 常驻，
    // 把整体常驻内存从 ~20-45MB 降到 ~3-6MB。
    // 延迟 3s：确保 ensureSupervisorRunning 的初始 spawn(同步) + 2s 复查均已完成。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (launchBgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:launchBgTask];
            launchBgTask = UIBackgroundTaskInvalid;
        }
        NSLog(@"[matisu] bootstrap complete, exiting app process (supervisor continues running)");
        exit(0);
    });

    return YES;
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

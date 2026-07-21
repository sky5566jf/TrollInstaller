//
//  MatisuHotspotManager.h
//  Matisu巨魔助手 — NEHotspotHelper 重启自启管理器
//
//  纯 TrollStore 非越狱环境下，实现"手机重启 + WiFi 连接后自动拉起 supervisor"的核心机制。
//  参考 TrollVNC TVNCHotspotManager 的实现：
//
//  1. NEHotspotHelper 注册 → 系统在 WiFi 关联时冷启动 App → handler 拉起 supervisor
//  2. SCNetworkReachability 兜底 → App 存活时网络变化补拉起
//  3. UIApplicationDidBecomeActive 兜底 → App 回前台时确认 supervisor 在运行
//  4. BGTaskScheduler 周期后台任务 → 定期确认 supervisor 存活
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatisuHotspotManager : NSObject

/// 单例
+ (instancetype)sharedManager;

/// 注册 NEHotspotHelper + 启动网络可达性监控
/// @param name WiFi 认证 UI 上显示的名称
/// @return 注册是否成功
- (BOOL)registerWithName:(NSString *)name;

/// 确保 supervisor 在运行（带 beginBackgroundTask 保命）
/// 被 HotspotHelper handler / Reachability / BGTask / DidBecomeActive 调用
- (void)ensureSupervisorRunning;

/// 启动 SCNetworkReachability 网络变化监控
- (void)startNetworkReachabilityMonitor;

@end

NS_ASSUME_NONNULL_END

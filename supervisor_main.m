//
//  supervisor_main.m
//  Matisu巨魔助手 — 常驻监督器(resident supervisor)
//
//  纯 TrollStore 非越狱下实现"App 划掉后 API 继续工作"的核心机制。
//  参考 TrollVNC trollvncmanager 的 resident supervisor 模式：
//
//  1. setsid() 脱离 App 的进程组/会话 → App 被杀时给进程组发信号不影响本进程
//  2. 忽略 SIGHUP/SIGINT/SIGTERM → App 关闭时传递的终止信号被吞掉
//  3. 单例锁文件 → 防止 App 多次启动时重复 spawn
//  4. vnode 监控自身二进制 → 只有 App 卸载(二进制被删)才退出
//  5. 直接跑 HTTPServer @8588 → CFRunLoop 常驻
//

#import <Foundation/Foundation.h>
#import "HTTPServer.h"
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <spawn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 单例锁文件路径：/var/mobile/Library/Caches 在 mobile 用户下可写
#define SUP_LOCK_PATH "/var/mobile/Library/Caches/com.matisu.trollassistant.supervisor.pid"
#define SUP_LOCK_FALLBACK "/tmp/com.matisu.trollassistant.supervisor.pid"

/// App 关闭时会给本进程组发 SIGHUP/SIGTERM，吞掉它们让 supervisor 存活
static void supervisorSignalHandler(int sig) {
    fprintf(stderr, "[supervisor] ignoring signal %d (resident mode)\n", sig);
    // 不退出 —— 吞掉信号
}

/// 监控自身二进制：只有被删除(App 卸载)时才退出
static void monitorSelfDeletion(const char *executable) {
    int fd = open(executable, O_EVTONLY);
    if (fd <= 0) return;

    dispatch_source_t source =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                               DISPATCH_VNODE_DELETE, dispatch_get_main_queue());

    __block dispatch_source_t sourceRef = source;
    dispatch_source_set_event_handler(source, ^{
        unsigned long flags = dispatch_source_get_data(sourceRef);
        if (flags & DISPATCH_VNODE_DELETE) {
            fprintf(stderr, "[supervisor] binary deleted, exiting\n");
            dispatch_source_cancel(sourceRef);
            exit(EXIT_SUCCESS);
        }
    });

    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });

    dispatch_resume(source);
    fprintf(stderr, "[supervisor] vnode monitor armed on %s\n", executable);
}

int main(int argc, const char *argv[]) {
    // ── --launch <bundle_id> 模式 ──
    // 由 spawnAsRoot 以 root 身份调用，以 root 身份 dlopen FrontBoard/SBS → 启动 App → 退出
    // 用法：matisusupervisor --launch <bundle_id>
    // 所有 ObjC 调用用 performSelector + NSClassFromString，避免编译器类型检查
    if (argc >= 3 && strcmp(argv[1], "--launch") == 0) {
        const char *bundleId = argv[2];
        fprintf(stderr, "[supervisor] --launch mode: bundleId=%s\n", bundleId);

        @autoreleasepool {
            NSString *nsBundleId = [NSString stringWithUTF8String:bundleId];

            // 方法1: SBSLaunchApplicationWithIdentifierAndLaunchOptions (SpringBoardServices C 函数)
            // 不同 iOS 版本有不同参数签名，依次尝试
            void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            if (sbsHandle) {
                // 变体1: 6参数 — (bundleID, suspended:BOOL, options:dict, launchResult:dict, result:dict, error)
                typedef int (*SBSLaunch6)(id, BOOL, id, id, id, NSError**);
                SBSLaunch6 sbsLaunch6 = (SBSLaunch6)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
                if (sbsLaunch6) {
                    NSError *error = nil;
                    int ret = sbsLaunch6(nsBundleId, NO, nil, nil, nil, &error);
                    fprintf(stderr, "[supervisor] SBSLaunch(6param,suspended=NO) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                    // 6参数失败，不直接放弃——可能签名不对，继续尝试其他变体
                }

                // 变体2: 5参数 — (bundleID, suspended:BOOL, options:dict, launchResult:dict, error)
                typedef int (*SBSLaunch5)(id, BOOL, id, id, NSError**);
                SBSLaunch5 sbsLaunch5 = (SBSLaunch5)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
                if (sbsLaunch5) {
                    NSError *error = nil;
                    int ret = sbsLaunch5(nsBundleId, NO, nil, nil, &error);
                    fprintf(stderr, "[supervisor] SBSLaunch(5param,suspended=NO) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                }

                // 变体3: 4参数 — (bundleID, options:dict, launchResult:dict, error)
                typedef int (*SBSLaunch4)(id, id, id, NSError**);
                SBSLaunch4 sbsLaunch4 = (SBSLaunch4)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
                if (sbsLaunch4) {
                    NSError *error = nil;
                    int ret = sbsLaunch4(nsBundleId, nil, nil, &error);
                    fprintf(stderr, "[supervisor] SBSLaunch(4param) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                }

                // 变体4: 2参数 — SBSLaunchApplicationWithIdentifier(bundleID, error)
                typedef int (*SBSLaunch2)(id, NSError**);
                SBSLaunch2 sbsLaunch2 = (SBSLaunch2)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifier");
                if (sbsLaunch2) {
                    NSError *error = nil;
                    int ret = sbsLaunch2(nsBundleId, &error);
                    fprintf(stderr, "[supervisor] SBSLaunch(2param) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                }

                // 方法2: SBSOpenSensitiveURLAndUnlockDevice — 通过 URL scheme 启动
                // 先 dlopen MobileCoreServices（LSApplicationWorkspace 所在框架）
                void *mcHandle = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
                if (!mcHandle) {
                    mcHandle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
                }
                fprintf(stderr, "[supervisor] MobileCoreServices dlopen: %s\n", mcHandle ? "ok" : (dlerror() ? dlerror() : "null"));

                @try {
                    Class LSAppCls = NSClassFromString(@"LSApplicationWorkspace");
                    fprintf(stderr, "[supervisor] LSApplicationWorkspace class: %s\n",
                            LSAppCls ? NSStringFromClass(LSAppCls).UTF8String : "nil");
                    if (LSAppCls) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id ws = [LSAppCls performSelector:@selector(defaultWorkspace)];
                        fprintf(stderr, "[supervisor] defaultWorkspace obj class: %s\n",
                                ws ? NSStringFromClass([ws class]).UTF8String : "nil");

                        // 尝试多个可能的 selector 名
                        id proxy = nil;
                        SEL sel1 = NSSelectorFromString(@"applicationProxyForBundleIdentifier:");
                        SEL sel2 = NSSelectorFromString(@"applicationProxyForIdentifier:");
                        if ([ws respondsToSelector:sel1]) {
                            proxy = [ws performSelector:sel1 withObject:nsBundleId];
                            fprintf(stderr, "[supervisor] used applicationProxyForBundleIdentifier:\n");
                        } else if ([ws respondsToSelector:sel2]) {
                            proxy = [ws performSelector:sel2 withObject:nsBundleId];
                            fprintf(stderr, "[supervisor] used applicationProxyForIdentifier:\n");
                        } else {
                            fprintf(stderr, "[supervisor] LSApplicationWorkspace has no applicationProxy selectors\n");
                            // 备选: allInstalledApplications → 手动过滤
                            SEL selAll = NSSelectorFromString(@"allInstalledApplications");
                            if ([ws respondsToSelector:selAll]) {
                                NSArray *allApps = [ws performSelector:selAll];
                                fprintf(stderr, "[supervisor] allInstalledApplications count: %lu\n", (unsigned long)allApps.count);
                                for (id app in allApps) {
                                    NSString *bid = [app performSelector:NSSelectorFromString(@"bundleIdentifier")];
                                    if ([bid isEqualToString:nsBundleId]) {
                                        proxy = app;
                                        fprintf(stderr, "[supervisor] found %s in allInstalledApplications\n", bundleId);
                                        break;
                                    }
                                }
                            }
                        }

                        if (proxy) {
                            fprintf(stderr, "[supervisor] proxy class: %s\n",
                                    NSStringFromClass([proxy class]).UTF8String);
                            SEL selSchemes = NSSelectorFromString(@"URLSchemes");
                            if ([proxy respondsToSelector:selSchemes]) {
                                NSArray *schemes = [proxy performSelector:selSchemes];
                                fprintf(stderr, "[supervisor] URL schemes count: %lu\n", (unsigned long)schemes.count);
                                if (schemes && schemes.count > 0) {
                                    NSString *firstScheme = schemes[0];
                                    NSString *urlStr = [firstScheme stringByAppendingString:@"://"];
                                    NSURL *url = [NSURL URLWithString:urlStr];

                                    typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef, int);
                                    SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
                                    if (openSensitive && url) {
                                        openSensitive((__bridge CFURLRef)url, 1);
                                        fprintf(stderr, "[supervisor] SBSOpenSensitiveURL: %s\n", [urlStr UTF8String]);
                                        if (mcHandle) dlclose(mcHandle);
                                        dlclose(sbsHandle);
                                        return EXIT_SUCCESS;
                                    }
                                }
                            } else {
                                fprintf(stderr, "[supervisor] proxy doesn't respond to URLSchemes\n");
                            }
                            fprintf(stderr, "[supervisor] no URL schemes found for %s\n", bundleId);
                        } else {
                            fprintf(stderr, "[supervisor] no app proxy for %s\n", bundleId);
                        }
#pragma clang diagnostic pop
                    }
                } @catch (NSException *ex) {
                    fprintf(stderr, "[supervisor] URL scheme lookup exception: %s — %s\n",
                            [[ex name] UTF8String], [[ex reason] UTF8String]);
                }

                if (mcHandle) dlclose(mcHandle);
                dlclose(sbsHandle);
            } else {
                const char *dlErr = dlerror();
                fprintf(stderr, "[supervisor] dlopen SBS failed: %s\n", dlErr ? dlErr : "(null)");
            }

            fprintf(stderr, "[supervisor] ALL launch methods failed for %s\n", bundleId);
        }
        return EXIT_FAILURE;
    }

    // 必须以绝对路径运行（vnode 监控需要）
    if (!argv || !argv[0] || argv[0][0] != '/') {
        fprintf(stderr, "[supervisor] must run from absolute path (got: %s)\n",
                argv ? argv[0] : "(null)");
        return EXIT_FAILURE;
    }

    // ── 1. 脱离 App 的进程组/会话 ──
    // App 被划掉时 iOS 给整个进程组发 SIGTERM；setsid 让本进程脱离该组，
    // 内核将本进程重新挂到 launchd 名下，App 死亡不影响 supervisor。
    pid_t newSession = setsid();
    if (newSession == -1) {
        // EPERM(已是会话组长) 时可忽略；其他错误记录但继续
        fprintf(stderr, "[supervisor] setsid() warning: %s (continuing)\n", strerror(errno));
    } else {
        fprintf(stderr, "[supervisor] detached from app process group (sid=%d)\n", newSession);
    }

    // ── 2. 忽略 App 关闭时传递的终止信号 ──
    signal(SIGHUP, supervisorSignalHandler);
    signal(SIGINT, supervisorSignalHandler);
    signal(SIGTERM, supervisorSignalHandler);
    signal(SIGPIPE, SIG_IGN);

    // ── 3. 单例锁：防止 App 多次启动时重复 spawn ──
    int lockFD = open(SUP_LOCK_PATH, O_RDWR | O_CREAT, 0644);
    if (lockFD == -1) {
        // /var/mobile/Library/Caches 不可写时 fallback 到 /tmp
        lockFD = open(SUP_LOCK_FALLBACK, O_RDWR | O_CREAT, 0644);
    }
    if (lockFD == -1) {
        fprintf(stderr, "[supervisor] cannot open lock file, continuing without singleton guard\n");
    } else {
        struct flock fl;
        fl.l_type = F_WRLCK;
        fl.l_whence = SEEK_SET;
        fl.l_start = 0;
        fl.l_len = 0; // 锁整个文件
        if (fcntl(lockFD, F_SETLK, &fl) == -1) {
            fprintf(stderr, "[supervisor] another instance already running, exiting\n");
            close(lockFD);
            return EXIT_FAILURE;
        }
        // 写入 PID
        ftruncate(lockFD, 0);
        char pidStr[16];
        int len = snprintf(pidStr, sizeof(pidStr), "%d\n", (int)getpid());
        if (write(lockFD, pidStr, (size_t)len) != len) {
            // 非致命
        }
        // lockFD 保持打开以维持锁，进程退出时自动释放
    }

    // ── 4. 监控自身二进制(卸载才退出) ──
    monitorSelfDeletion(argv[0]);

    // ── 5. 启动 HTTPServer 并常驻 ──
    @autoreleasepool {
        fprintf(stderr, "[supervisor] launching (pid=%d, ppid=%d, exec=%s)\n",
                (int)getpid(), (int)getppid(), argv[0]);

        HTTPServer *server = [HTTPServer sharedServer];
        NSError *err = nil;
        if (![server start:&err]) {
            fprintf(stderr, "[supervisor] HTTPServer start failed: %s\n",
                    [[err localizedDescription] UTF8String]);
            return EXIT_FAILURE;
        }
        fprintf(stderr, "[supervisor] HTTPServer listening on :%d\n", server.port);
        fprintf(stderr, "[supervisor] resident mode active — will survive app termination\n");

        // HTTPServer 在工作线程处理请求，主线程跑 CFRunLoop 常驻
        CFRunLoopRun();
    }

    return EXIT_SUCCESS;
}

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
            // 方法1: SBSLaunchApplicationWithIdentifierAndLaunchOptions (SpringBoardServices C 函数)
            // 直接按 bundle ID 启动 App，不需要 URL scheme，不需要 FrontBoard ObjC 类
            void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            if (sbsHandle) {
                // SBSLaunchApplicationWithIdentifierAndLaunchOptions signature:
                // int SBSLaunchApplicationWithIdentifierAndLaunchOptions(NSString *bundleID, NSDictionary *options, NSDictionary *launchResult, NSError **error)
                // 尝试多种签名变体（不同 iOS 版本参数个数不同）
                
                // 变体1: 4参数 (bundleID, options, launchResult, error)
                typedef int (*SBSLaunch4)(id, id, id, NSError**);
                SBSLaunch4 sbsLaunch4 = (SBSLaunch4)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
                if (sbsLaunch4) {
                    NSString *nsBundleId = [NSString stringWithUTF8String:bundleId];
                    NSError *error = nil;
                    int ret = sbsLaunch4(nsBundleId, nil, nil, &error);
                    fprintf(stderr, "[supervisor] SBSLaunchApp(4param) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                }

                // 变体2: 2参数 (bundleID, error)
                typedef int (*SBSLaunch2)(id, NSError**);
                SBSLaunch2 sbsLaunch2 = (SBSLaunch2)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifier");
                if (sbsLaunch2) {
                    NSString *nsBundleId = [NSString stringWithUTF8String:bundleId];
                    NSError *error = nil;
                    int ret = sbsLaunch2(nsBundleId, &error);
                    fprintf(stderr, "[supervisor] SBSLaunchApp(2param) ret=%d, err=%s\n",
                            ret, error ? [[error localizedDescription] UTF8String] : "none");
                    if (ret == 0) { dlclose(sbsHandle); return EXIT_SUCCESS; }
                }

                // 方法2: SBSOpenSensitiveURLAndUnlockDevice — 通过 URL scheme 启动
                // 先查找 App 的 URL scheme，再通过 SBS 打开
                @try {
                    NSString *nsBundleId = [NSString stringWithUTF8String:bundleId];
                    Class LSAppCls = NSClassFromString(@"LSApplicationWorkspace");
                    if (LSAppCls) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id ws = [LSAppCls performSelector:@selector(defaultWorkspace)];
                        // 修复：正确的 selector 是 applicationProxyForBundleIdentifier:
                        id proxy = [ws performSelector:@selector(applicationProxyForBundleIdentifier:) withObject:nsBundleId];
#pragma clang diagnostic pop
                        if (proxy) {
                            NSArray *schemes = [proxy performSelector:@selector(URLSchemes)];
                            if (schemes && schemes.count > 0) {
                                NSString *firstScheme = schemes[0];
                                NSString *urlStr = [firstScheme stringByAppendingString:@"://"];
                                NSURL *url = [NSURL URLWithString:urlStr];

                                typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef, int);
                                SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
                                if (openSensitive && url) {
                                    openSensitive((__bridge CFURLRef)url, 1);
                                    fprintf(stderr, "[supervisor] SBSOpenSensitiveURL: %s\n", [urlStr UTF8String]);
                                    dlclose(sbsHandle);
                                    return EXIT_SUCCESS;
                                }
                            }
                            fprintf(stderr, "[supervisor] no URL schemes for %s\n", bundleId);
                        } else {
                            fprintf(stderr, "[supervisor] no app proxy for %s\n", bundleId);
                        }
                    }
                } @catch (NSException *ex) {
                    fprintf(stderr, "[supervisor] URL scheme lookup crashed: %s\n", [[ex reason] UTF8String]);
                }

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

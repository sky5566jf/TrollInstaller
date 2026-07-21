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

            // 尝试方法1: FBSOpenApplication (FrontBoard) — 按 bundle ID 启动
            // FrontBoard 框架的 ObjC 类在 runtime 通过 NSClassFromString 获取
            void *fbHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_LAZY);
            if (fbHandle) {
                Class FBSOpenAppCls = NSClassFromString(@"FBSOpenApplication");
                if (FBSOpenAppCls) {
                    // FBSOpenApplication 的初始化方法名可能不同版本不同
                    // 尝试多种 init 方法：initWithApplicationIdentifier / initWithBundleID
                    id openApp = nil;
                    SEL initSel1 = NSSelectorFromString(@"initWithApplicationIdentifier:");
                    SEL initSel2 = NSSelectorFromString(@"initWithBundleID:");
                    
                    if ([FBSOpenAppCls instancesRespondToSelector:initSel1]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        openApp = [[FBSOpenAppCls alloc] performSelector:initSel1 withObject:nsBundleId];
#pragma clang diagnostic pop
                    } else if ([FBSOpenAppCls instancesRespondToSelector:initSel2]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        openApp = [[FBSOpenAppCls alloc] performSelector:initSel2 withObject:nsBundleId];
#pragma clang diagnostic pop
                    }

                    if (openApp) {
                        // 尝试 open 方法
                        SEL openSel = NSSelectorFromString(@"openApplicationWithResult:andError:");
                        SEL openSel2 = NSSelectorFromString(@"openApplicationWithError:");
                        
                        if ([openApp respondsToSelector:openSel] || [openApp respondsToSelector:openSel2]) {
                            // 用 msg_send stub 避免 NSError** 桥接问题
                            // performSelector 只能传 id 参数，不能传 NSError**
                            // 所以用 objc_msgSend 直接调用
                            typedef BOOL (*msgSendType)(id, SEL, id, NSError**);
                            SEL useSel = [openApp respondsToSelector:openSel] ? openSel : openSel2;
                            NSError *error = nil;
                            BOOL success = ((msgSendType)objc_msgSend)(openApp, useSel, nil, &error);
                            fprintf(stderr, "[supervisor] FBSOpenApplication result=%d, error=%s\n",
                                    success, error ? [[error localizedDescription] UTF8String] : "none");
                            dlclose(fbHandle);
                            return success ? EXIT_SUCCESS : EXIT_FAILURE;
                        }
                        fprintf(stderr, "[supervisor] FBSOpenApplication has no known open method\n");
                    } else {
                        fprintf(stderr, "[supervisor] FBSOpenApplication init failed\n");
                    }
                } else {
                    fprintf(stderr, "[supervisor] FBSOpenApplication class not found\n");
                }

                // 尝试 C 函数版本
                typedef int (*FBSOpenAppFunc)(const char *, void *, void *);
                FBSOpenAppFunc fbOpen = (FBSOpenAppFunc)dlsym(fbHandle, "FBSOpenApplication");
                if (fbOpen) {
                    int ret = fbOpen(bundleId, NULL, NULL);
                    fprintf(stderr, "[supervisor] FBSOpenApplication(C) result=%d\n", ret);
                    dlclose(fbHandle);
                    return (ret == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
                }
                dlclose(fbHandle);
            } else {
                const char *dlErr = dlerror();
                fprintf(stderr, "[supervisor] dlopen FrontBoard failed: %s\n", dlErr ? dlErr : "(null)");
            }

            // 尝试方法2: SBSOpenSensitiveURLAndUnlockDevice — 通过 URL scheme 启动
            void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            if (sbsHandle) {
                // 通过 LSApplicationWorkspace 查找 App 的 URL scheme
                Class LSAppCls = NSClassFromString(@"LSApplicationWorkspace");
                if (LSAppCls) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id ws = [LSAppCls performSelector:@selector(defaultWorkspace)];
                    id proxy = [ws performSelector:@selector(applicationProxyForIdentifier:) withObject:nsBundleId];
#pragma clang diagnostic pop
                    if (proxy) {
                        NSArray *schemes = [proxy performSelector:@selector(URLSchemes)];
                        if (schemes && schemes.count > 0) {
                            NSString *firstScheme = schemes[0];
                            NSString *urlStr = [firstScheme stringByAppendingString:@"://"];
                            NSURL *url = [NSURL URLWithString:urlStr];

                            typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef url, int flags);
                            SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
                            if (openSensitive && url) {
                                openSensitive((__bridge CFURLRef)url, 1);
                                fprintf(stderr, "[supervisor] SBSOpenSensitiveURL: %s\n", [urlStr UTF8String]);
                                dlclose(sbsHandle);
                                return EXIT_SUCCESS;
                            }

                            typedef void (*SBSOpenURLFunc)(CFURLRef url);
                            SBSOpenURLFunc openURLFunc = (SBSOpenURLFunc)dlsym(sbsHandle, "SBSOpenURL");
                            if (openURLFunc && url) {
                                openURLFunc((__bridge CFURLRef)url);
                                fprintf(stderr, "[supervisor] SBSOpenURL: %s\n", [urlStr UTF8String]);
                                dlclose(sbsHandle);
                                return EXIT_SUCCESS;
                            }
                        }
                        fprintf(stderr, "[supervisor] no URL schemes found for %s\n", bundleId);
                    } else {
                        fprintf(stderr, "[supervisor] no LSApplicationProxy for %s\n", bundleId);
                    }
                }
                dlclose(sbsHandle);
            } else {
                const char *dlErr = dlerror();
                fprintf(stderr, "[supervisor] dlopen SpringBoardServices failed: %s\n", dlErr ? dlErr : "(null)");
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

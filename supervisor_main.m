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

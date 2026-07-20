#import "AppDelegate.h"
#import "ViewController.h"
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 拉起常驻监督器(resident supervisor)：
    // supervisor 会 setsid() 脱离本 App 的进程组，并忽略终止信号，
    // 因此 App 被划掉后 supervisor 继续存活，8588 API 不断。
    [self launchSupervisor];

    return YES;
}

/// posix_spawn 拉起常驻监督器二进制（与 App 同 bundle）
- (void)launchSupervisor {
    NSString *supPath = [[NSBundle mainBundle] pathForResource:@"matisusupervisor" ofType:nil];
    if (!supPath) {
        NSLog(@"[app] supervisor binary not found in bundle");
        return;
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
        NSLog(@"[app] supervisor launched, pid=%d", pid);
        // 不 waitpid —— 让 supervisor 独立运行(它会 setsid 脱离本进程组)
    } else {
        NSLog(@"[app] posix_spawn supervisor failed: %s", strerror(rc));
    }
}

@end

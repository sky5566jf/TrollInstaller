#import "HTTPServer.h"
#import <dispatch/dispatch.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#include <signal.h>

#define TI_PORT 8588

// ── iOS 私有 persona API：posix_spawn 提权为 root ──
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict attr,
                                          uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict attr,
                                               uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict attr,
                                               gid_t gid);

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

/*
 * LSApplicationWorkspace — 后台守护进程也能打开 URL（不依赖 UIApplication）。
 * 运行时通过 NSClassFromString 调用，无需链接私有框架。
 */
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

#pragma mark - sendAll：循环写入处理部分写入

/// 循环 send 直到所有字节发完或连接断开
/// 解决 send() 可能只发送部分字节导致响应被截断的问题
static void sendAll(int fd, const char *data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, data + sent, (int)(len - sent), 0);
        if (n <= 0) {
            if (errno == EINTR) continue;  // 被信号中断，重试
            break;  // 连接断开或出错
        }
        sent += (size_t)n;
    }
}

@implementation HTTPServer {
    BOOL _running;
    int _listenSock;
}

+ (instancetype)sharedServer {
    static HTTPServer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[HTTPServer alloc] init]; });
    return s;
}

- (int)port { return TI_PORT; }

- (void)start {
    NSError *e = nil;
    if (![self start:&e]) {
        NSLog(@"[HTTPServer] 未启动(可能守护进程已占用 :%d): %@",
              TI_PORT, e.localizedDescription);
    } else {
        NSLog(@"[HTTPServer] 监听 :%d", TI_PORT);
    }
}

- (BOOL)start:(NSError **)error {
    if (_running) return YES;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        if (error) *error = [NSError errorWithDomain:@"HTTPServer" code:1
                                userInfo:@{NSLocalizedDescriptionKey:@"socket() 失败"}];
        return NO;
    }

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TI_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        if (error) *error = [NSError errorWithDomain:@"HTTPServer" code:2
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"bind :%d 失败(端口被占用?)", TI_PORT]}];
        return NO;
    }
    if (listen(sock, 16) < 0) {
        close(sock);
        if (error) *error = [NSError errorWithDomain:@"HTTPServer" code:3
                                userInfo:@{NSLocalizedDescriptionKey:@"listen() 失败"}];
        return NO;
    }

    _listenSock = sock;
    _running = YES;
    [NSThread detachNewThreadSelector:@selector(runLoop) toTarget:self withObject:nil];
    return YES;
}

#pragma mark - 多线程 accept 循环

/// accept 循环：每个连接 dispatch 到后台并发队列处理
/// 消除单线程阻塞 —— 一个慢请求（如下载50MB tipa）不再卡死其他 API 请求
- (void)runLoop {
    while (_running) {
        int client = accept(_listenSock, NULL, NULL);
        if (client < 0) {
            if (_running) continue;
            break;
        }

        // 设置 recv 超时（30秒），防止恶意客户端永久阻塞工作线程
        struct timeval tv;
        tv.tv_sec = 30;
        tv.tv_usec = 0;
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        // 设置 send 超时（30秒）
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        // dispatch 到全局并发队列，多连接并行处理
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                [self handleClient:client];
            }
            close(client);
        });
    }
    if (_listenSock >= 0) close(_listenSock);
    _listenSock = -1;
}

- (void)handleClient:(int)client {
    char buf[4096];
    NSMutableData *reqData = [NSMutableData data];
    ssize_t n;
    while ((n = recv(client, buf, sizeof(buf) - 1, 0)) > 0) {
        [reqData appendBytes:buf length:(NSUInteger)n];
        const char *p = reqData.bytes;
        size_t len = reqData.length;
        BOOL found = NO;
        for (size_t i = 0; i + 3 < len; i++) {
            if (p[i] == '\r' && p[i+1] == '\n' && p[i+2] == '\r' && p[i+3] == '\n') {
                found = YES;
                break;
            }
        }
        if (found) break;
    }

    NSString *req = [[NSString alloc] initWithData:reqData encoding:NSUTF8StringEncoding];
    if (req.length == 0) {
        [self send:client status:400 body:@"Bad Request" type:@"text/plain"];
        return;
    }

    NSString *firstLine = [[req componentsSeparatedByString:@"\r\n"] firstObject];
    NSArray *parts = [firstLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self send:client status:400 body:@"Bad Request" type:@"text/plain"];
        return;
    }
    NSString *target = parts[1];

    if ([target hasPrefix:@"/install"]) {
        [self handleInstall:client target:target];
        return;
    }

    if ([target hasPrefix:@"/uninstall"]) {
        [self handleUninstall:client target:target];
        return;
    }

    if ([target hasPrefix:@"/status"]) {
        [self handleStatus:client];
        return;
    }

    NSString *body = @"{\"status\":\"Matisu Troll Assistant API\",\"port\":8588,\"endpoints\":[\"/install\",\"/uninstall\",\"/status\"]}";
    [self send:client status:200 body:body type:@"application/json"];
}

#pragma mark - /status 端点

/// /status — 返回 supervisor 运行状态、trollstorehelper 路径等信息
- (void)handleStatus:(int)client {
    // 检查 supervisor 是否在运行
    NSString *lockPath = @"/var/mobile/Library/Caches/com.matisu.trollassistant.supervisor.pid";
    NSString *pidStr = [NSString stringWithContentsOfFile:lockPath encoding:NSUTF8StringEncoding error:nil];
    NSInteger supPid = [pidStr integerValue];
    BOOL supRunning = (supPid > 0 && kill((pid_t)supPid, 0) == 0);

    // 检查 trollstorehelper
    NSString *helperPath = [self findTrollStoreHelper];
    NSString *escHelper = [self jsonEscape:helperPath ?: @"not_found"];

    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"port\":%d,\"supervisor\":{\"pid\":%ld,\"running\":%@},\"trollstorehelper\":\"%@\"}",
        TI_PORT, (long)supPid, supRunning ? @"true" : @"false", escHelper];
    [self send:client status:200 body:body type:@"application/json"];
}

#pragma mark - TrollStore Helper 查找（带缓存）

/// trollstorehelper 路径缓存
/// 路径在设备上基本不变，缓存后避免每次请求都全盘扫描
static NSString *sCachedHelperPath = nil;

/// 查找 trollstorehelper（带缓存）
- (NSString *)findTrollStoreHelper {
    @synchronized([HTTPServer class]) {
        // 缓存命中且路径仍有效
        if (sCachedHelperPath && access([sCachedHelperPath UTF8String], X_OK) == 0) {
            return sCachedHelperPath;
        }
        // 缓存未命中或路径已失效，重新搜索
        sCachedHelperPath = [self findTrollStoreHelperUncached];
        return sCachedHelperPath;
    }
}

/// 不带缓存的原始搜索逻辑
- (NSString *)findTrollStoreHelperUncached {
    // 固定路径列表（越狱环境、旧版 TrollStore）
    NSArray *fixedPaths = @[
        @"/var/containers/Bundle/Application/com.opa334.TrollStore/trollstorehelper",
        @"/var/mobile/trollstorehelper",
        @"/Applications/TrollStore.app/trollstorehelper",
        @"/usr/bin/trollstorehelper",
        @"/usr/local/bin/trollstorehelper",
        @"/var/jb/usr/bin/trollstorehelper",
        @"/var/jb/bin/trollstorehelper"
    ];
    for (NSString *p in fixedPaths) {
        if (access([p UTF8String], X_OK) == 0) {
            NSLog(@"[HTTPServer] found trollstorehelper (fixed): %@", p);
            return p;
        }
    }

    // 动态搜索 UUID 格式安装路径（TrollStore 非越狱环境）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *searchDirs = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application"
    ];
    for (NSString *searchDir in searchDirs) {
        NSError *err = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:searchDir error:&err];
        if (!contents) continue;

        for (NSString *uuidDir in contents) {
            NSString *fullPath = [searchDir stringByAppendingPathComponent:uuidDir];

            BOOL isTrollStoreDir = ([uuidDir rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                    [uuidDir rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (isTrollStoreDir) {
                NSString *helper = [fullPath stringByAppendingPathComponent:@"trollstorehelper"];
                if (access([helper UTF8String], X_OK) == 0) {
                    NSLog(@"[HTTPServer] found trollstorehelper (UUID dir): %@", helper);
                    return helper;
                }
            }

            NSArray *subContents = [fm contentsOfDirectoryAtPath:fullPath error:nil];
            for (NSString *sub in subContents) {
                if ([sub hasSuffix:@".app"] &&
                    ([sub rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [sub rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    NSString *helper = [[fullPath stringByAppendingPathComponent:sub]
                                        stringByAppendingPathComponent:@"trollstorehelper"];
                    if (access([helper UTF8String], X_OK) == 0) {
                        NSLog(@"[HTTPServer] found trollstorehelper (app bundle): %@", helper);
                        return helper;
                    }
                }
            }
        }
    }

    NSLog(@"[HTTPServer] trollstorehelper not found anywhere");
    return nil;
}

#pragma mark - 以 root 身份 spawn 进程（persona_np 提权）

static int spawnAsRootWithOutput(NSString *path, NSArray *args, NSString **outputOut) {
    if (!path) return -1;

    NSMutableArray *fullArgv = [NSMutableArray arrayWithObject:path];
    if (args) [fullArgv addObjectsFromArray:args];

    char **argv = (char **)malloc((fullArgv.count + 1) * sizeof(char *));
    for (NSUInteger i = 0; i < fullArgv.count; i++) {
        argv[i] = (char *)[fullArgv[i] UTF8String];
    }
    argv[fullArgv.count] = NULL;

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        NSLog(@"[HTTPServer] pipe() failed: %s", strerror(errno));
        free(argv);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    pid_t pid;
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawn(&pid, [path UTF8String], &actions, &attr, argv, NULL);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    free(argv);

    if (err != 0) {
        NSLog(@"[HTTPServer] posix_spawn failed: %d (%s)", err, strerror(err));
        close(pipefd[0]); close(pipefd[1]);
        return err;
    }

    close(pipefd[1]);

    NSMutableData *outData = [NSMutableData data];
    char buf[4096];
    ssize_t nr;
    while ((nr = read(pipefd[0], buf, sizeof(buf))) > 0) {
        [outData appendBytes:buf length:(NSUInteger)nr];
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WEXITSTATUS(status);

    if (outputOut) {
        *outputOut = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    }

    NSLog(@"[HTTPServer] spawnAsRoot: pid=%d exit=%d output=%s",
          pid, exitCode, outputOut ? [*outputOut UTF8String] : "(null)");

    return exitCode;
}

#pragma mark - 流式下载 tipa 到临时文件

/// 使用 NSURLSession downloadTask 流式下载 tipa 到临时文件
/// 替代原 NSData dataWithContentsOfURL: 方案：
///   1. 流式写入文件，不一次性占用整文件大小的内存
///   2. 有超时控制（request 120s，resource 300s）
///   3. NSURLSession 底层使用 SPDY/HTTP2，网络效率更高
- (NSString *)downloadToTemp:(NSString *)urlString error:(NSString **)errorOut {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (errorOut) *errorOut = @"invalid_url";
        return nil;
    }

    NSLog(@"[HTTPServer] downloading tipa from: %@", urlString);

    NSString *tempPath = [NSString stringWithFormat:@"/tmp/matisu_install_%lld.tipa",
                          (long long)(time(NULL))];

    // 配置 NSURLSession：带超时控制
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 120;   // 单个请求超时 2 分钟
    config.timeoutIntervalForResource = 300;   // 整个资源下载超时 5 分钟

    __block NSError *sessionError = nil;
    __block BOOL downloadComplete = NO;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                sessionError = error;
            } else if (location) {
                // downloadTask 已将数据写入系统临时文件，移动到我们的路径
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtURL:location
                                                         toURL:[NSURL fileURLWithPath:tempPath]
                                                         error:&moveError];
                if (moveError) {
                    sessionError = moveError;
                }
            }
            downloadComplete = YES;
        }];

    [task resume];

    // 在后台线程同步等待下载完成（runLoop 已 dispatch 到后台队列）
    while (!downloadComplete) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    [session invalidateAndCancel];

    if (sessionError) {
        NSString *errMsg = sessionError.localizedDescription ?: @"unknown_error";
        NSLog(@"[HTTPServer] download failed: %@", errMsg);
        if (errorOut) *errorOut = [NSString stringWithFormat:@"download_failed: %@", errMsg];
        unlink([tempPath UTF8String]);
        return nil;
    }

    // 验证下载文件非空
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tempPath error:nil];
    unsigned long long fileSize = [attrs fileSize];
    if (fileSize == 0) {
        NSLog(@"[HTTPServer] downloaded file is empty");
        if (errorOut) *errorOut = @"download_empty";
        unlink([tempPath UTF8String]);
        return nil;
    }

    NSLog(@"[HTTPServer] downloaded %llu bytes to: %@", fileSize, tempPath);
    return tempPath;
}

#pragma mark - JSON 字符串安全转义

- (NSString *)jsonEscape:(NSString *)s {
    if (!s) return @"";
    NSMutableString *ms = [NSMutableString stringWithString:s];
    [ms replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\r" withString:@"\\r" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\t" withString:@"\\t" options:0 range:NSMakeRange(0, ms.length)];
    return ms;
}

#pragma mark - 从 trollstorehelper 输出解析 bundle ID

- (NSString *)extractBundleIdFromOutput:(NSString *)output {
    if (!output || output.length == 0) return nil;

    // 方法1: 从 MCMAppContainer ID 行提取
    NSRange idRange = [output rangeOfString:@"ID: "];
    if (idRange.location != NSNotFound) {
        NSString *afterId = [output substringFromIndex:idRange.location + 4];
        NSRange spaceRange = [afterId rangeOfString:@" "];
        if (spaceRange.location != NSNotFound && spaceRange.location > 0) {
            NSString *bundleId = [afterId substringToIndex:spaceRange.location];
            if ([bundleId containsString:@"."]) {
                NSLog(@"[HTTPServer] extracted bundleId from MCMAppContainer: %@", bundleId);
                return bundleId;
            }
        }
    }

    // 方法2: 从 new app path 提取路径，读取 Info.plist 获取真实 CFBundleIdentifier
    NSRange pathRange = [output rangeOfString:@"[installApp] new app path: "];
    if (pathRange.location != NSNotFound) {
        NSString *afterPath = [output substringFromIndex:pathRange.location + 28];
        NSArray *pathParts = [afterPath componentsSeparatedByString:@"\n"];
        if (pathParts.count > 0) {
            NSString *appPath = [pathParts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
            if (infoPlist) {
                NSString *bundleId = infoPlist[@"CFBundleIdentifier"];
                if (bundleId && bundleId.length > 0) {
                    NSLog(@"[HTTPServer] extracted bundleId from Info.plist: %@", bundleId);
                    return bundleId;
                }
                NSLog(@"[HTTPServer] Info.plist found but CFBundleIdentifier missing: %@", infoPlistPath);
            } else {
                NSLog(@"[HTTPServer] cannot read Info.plist at: %@", infoPlistPath);
            }
        }
    }

    NSLog(@"[HTTPServer] cannot extract bundleId from trollstorehelper output");
    return nil;
}

#pragma mark - 启动已安装的 App

- (NSString *)launchApp:(NSString *)bundleId {
    NSString *execPath = [[NSProcessInfo processInfo] arguments][0];
    if (!execPath || execPath.length == 0) {
        NSLog(@"[HTTPServer] cannot determine own executable path");
        return @"no_exec_path";
    }

    NSLog(@"[HTTPServer] launching app %@ via spawnAsRoot(%@ --launch %@)", bundleId, execPath, bundleId);

    NSString *output = nil;
    int exitCode = spawnAsRootWithOutput(execPath,
                                         @[@"--launch", bundleId],
                                         &output);

    NSString *result = [NSString stringWithFormat:@"exitCode:%d|%s", exitCode,
                        output ? [output UTF8String] : "(no output)"];
    NSLog(@"[HTTPServer] launch result: %@", result);
    return result;
}

#pragma mark - 安装处理（核心 API）

- (void)handleInstall:(int)client target:(NSString *)target {
    NSString *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound && q.location + 1 < target.length) {
        query = [target substringFromIndex:q.location + 1];
    }

    // ── 解析 url 参数 ──
    NSString *urlParam = @"";
    NSRange urlRange = [query rangeOfString:@"url="];
    if (urlRange.location != NSNotFound) {
        urlParam = [query substringFromIndex:urlRange.location + urlRange.length];
        NSRange ampRange = [urlParam rangeOfString:@"&"];
        if (ampRange.location != NSNotFound) {
            urlParam = [urlParam substringToIndex:ampRange.location];
        }
    }
    if (urlParam.length == 0) {
        NSString *body = @"{\"status\":\"error\",\"msg\":\"url required\"}";
        [self send:client status:400 body:body type:@"application/json"];
        return;
    }

    NSString *decoded = [urlParam stringByRemovingPercentEncoding] ?: urlParam;

    // ── 解析 launch 参数 ──
    NSString *launchParam = nil;
    NSRange launchRange = [query rangeOfString:@"launch="];
    if (launchRange.location != NSNotFound) {
        launchParam = [query substringFromIndex:launchRange.location + launchRange.length];
        NSRange ampRange = [launchParam rangeOfString:@"&"];
        if (ampRange.location != NSNotFound) {
            launchParam = [launchParam substringToIndex:ampRange.location];
        }
        launchParam = [launchParam stringByRemovingPercentEncoding] ?: launchParam;
    }

    // ── 路径1: trollstorehelper 直接安装 ──
    NSString *helperPath = [self findTrollStoreHelper];
    if (helperPath) {
        NSLog(@"[HTTPServer] trying trollstorehelper direct install");

        NSString *dlError = nil;
        NSString *tempPath = [self downloadToTemp:decoded error:&dlError];
        if (tempPath) {
            NSString *output = nil;
            int exitCode = spawnAsRootWithOutput(helperPath,
                                                 @[@"install", tempPath],
                                                 &output);

            unlink([tempPath UTF8String]);

            NSString *statusStr = (exitCode == 0) ? @"ok" : @"error";
            NSString *escOutput = [self jsonEscape:output];
            NSString *escUrl = [self jsonEscape:decoded];

            // ── 安装成功后自动启动 App ──
            NSMutableArray *launchResultArray = [NSMutableArray array];
            if (exitCode == 0 && launchParam) {
                NSArray *bundleIds = nil;

                if ([launchParam isEqualToString:@"true"]) {
                    NSString *autoBid = [self extractBundleIdFromOutput:output];
                    NSLog(@"[HTTPServer] auto-detected bundleId: %@", autoBid);
                    if (autoBid) bundleIds = @[autoBid];
                } else {
                    bundleIds = [launchParam componentsSeparatedByString:@","];
                }

                NSLog(@"[HTTPServer] launching %lu app(s): %@", (unsigned long)bundleIds.count, bundleIds);

                NSUInteger launchIndex = 0;
                for (NSString *bid in bundleIds) {
                    NSString *trimmed = [bid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0) continue;

                    if (launchIndex > 0) {
                        NSLog(@"[HTTPServer] waiting 10s before launching next app: %@", trimmed);
                        sleep(10);
                    }

                    NSString *result = [self launchApp:trimmed];
                    [launchResultArray addObject:[NSString stringWithFormat:
                        @"{\"bundleId\":\"%@\",\"result\":\"%@\"}",
                        [self jsonEscape:trimmed], [self jsonEscape:result]]];
                    launchIndex++;
                }

                if (launchResultArray.count == 0 && bundleIds.count == 0) {
                    [launchResultArray addObject:@"{\"bundleId\":\"\",\"result\":\"no_bundle_id\"}"];
                }
            }

            NSString *launchJson = [launchResultArray componentsJoinedByString:@","];

            NSString *body = [NSString stringWithFormat:
                @"{\"status\":\"%@\",\"url\":\"%@\",\"method\":\"trollstorehelper\",\"exitCode\":%d,\"output\":\"%@\",\"launch\":[%@]}",
                statusStr, escUrl, exitCode, escOutput, launchJson];
            [self send:client status:(exitCode == 0 ? 200 : 500) body:body type:@"application/json"];
            return;
        }

        NSLog(@"[HTTPServer] download failed: %@, falling back to openURL", dlError);
    } else {
        NSLog(@"[HTTPServer] trollstorehelper not found, falling back to openURL");
    }

    // ── 路径2: openURL 兜底 ──
    NSString *scheme = [@"apple-magnifier://install?url=" stringByAppendingString:decoded];
    NSString *method = [self triggerInstall:scheme];

    NSString *escUrl = [self jsonEscape:decoded];
    NSString *escMethod = [self jsonEscape:method];
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"url\":\"%@\",\"method\":\"%@\"}", escUrl, escMethod];
    [self send:client status:200 body:body type:@"application/json"];
}

#pragma mark - 卸载处理（核心 API）

- (void)handleUninstall:(int)client target:(NSString *)target {
    NSString *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound && q.location + 1 < target.length) {
        query = [target substringFromIndex:q.location + 1];
    }

    NSString *bundleId = @"";
    NSRange bidRange = [query rangeOfString:@"bundle_id="];
    if (bidRange.location != NSNotFound) {
        bundleId = [query substringFromIndex:bidRange.location + bidRange.length];
        NSRange ampRange = [bundleId rangeOfString:@"&"];
        if (ampRange.location != NSNotFound) {
            bundleId = [bundleId substringToIndex:ampRange.location];
        }
    }
    if (bundleId.length == 0) {
        NSString *body = @"{\"status\":\"error\",\"msg\":\"bundle_id required\"}";
        [self send:client status:400 body:body type:@"application/json"];
        return;
    }

    bundleId = [bundleId stringByRemovingPercentEncoding] ?: bundleId;

    NSString *helperPath = [self findTrollStoreHelper];
    if (!helperPath) {
        NSLog(@"[HTTPServer] trollstorehelper not found, cannot uninstall");
        NSString *body = @"{\"status\":\"error\",\"msg\":\"trollstorehelper not found\"}";
        [self send:client status:500 body:body type:@"application/json"];
        return;
    }

    NSLog(@"[HTTPServer] uninstalling app: %@ via trollstorehelper", bundleId);

    NSString *output = nil;
    int exitCode = spawnAsRootWithOutput(helperPath,
                                         @[@"uninstall", bundleId],
                                         &output);

    NSString *statusStr = (exitCode == 0) ? @"ok" : @"error";
    NSString *escOutput = [self jsonEscape:output];
    NSString *escBid = [self jsonEscape:bundleId];

    NSLog(@"[HTTPServer] uninstall result: exitCode=%d bundleId=%@", exitCode, bundleId);

    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"bundleId\":\"%@\",\"method\":\"trollstorehelper\",\"exitCode\":%d,\"output\":\"%@\"}",
        statusStr, escBid, exitCode, escOutput];
    [self send:client status:(exitCode == 0 ? 200 : 500) body:body type:@"application/json"];
}

#pragma mark - openURL 兜底（三级 fallback）

- (NSString *)triggerInstall:(NSString *)scheme {
    NSURL *u = [NSURL URLWithString:scheme];
    if (!u) return @"invalid_url";

    void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbsHandle) {
        typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef url, int flags);
        SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
        if (openSensitive) {
            @try {
                openSensitive((__bridge CFURLRef)u, 1);
                NSLog(@"[HTTPServer] SBSOpenSensitiveURLAndUnlockDevice called: %@", scheme);
                dlclose(sbsHandle);
                return @"SBSOpenSensitiveURL";
            } @catch (NSException *e) {
                NSLog(@"[HTTPServer] SBSOpenSensitiveURL exception: %@", e);
            }
        }

        typedef void (*SBSOpenURLFunc)(CFURLRef url);
        SBSOpenURLFunc openURLFunc = (SBSOpenURLFunc)dlsym(sbsHandle, "SBSOpenURL");
        if (openURLFunc) {
            @try {
                openURLFunc((__bridge CFURLRef)u);
                NSLog(@"[HTTPServer] SBSOpenURL called: %@", scheme);
                dlclose(sbsHandle);
                return @"SBSOpenURL";
            } @catch (NSException *e) {
                NSLog(@"[HTTPServer] SBSOpenURL exception: %@", e);
            }
        }
        dlclose(sbsHandle);
    } else {
        const char *dlErr = dlerror();
        NSLog(@"[HTTPServer] dlopen SpringBoardServices failed: %s", dlErr ? dlErr : "(null)");
        return [NSString stringWithFormat:@"dlopen_failed:%s", dlErr ? dlErr : "null"];
    }

    // ── 方法3: LSApplicationWorkspace openURL: ──
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        id ws = [cls performSelector:@selector(defaultWorkspace)];
        BOOL ok = (BOOL)[ws performSelector:@selector(openURL:) withObject:u];
        NSLog(@"[HTTPServer] LSApplicationWorkspace openURL: result=%d, scheme=%@", ok, scheme);
        return ok ? @"LSApplicationWorkspace" : @"LSApplicationWorkspace_failed";
    }
#pragma clang diagnostic pop

    NSLog(@"[HTTPServer] ALL methods failed for: %@", scheme);
    return @"all_failed";
}

#pragma mark - HTTP 响应发送

/// 根据 HTTP 状态码返回标准 reason phrase
- (NSString *)reasonForStatus:(int)status {
    switch (status) {
        case 200: return @"OK";
        case 400: return @"Bad Request";
        case 404: return @"Not Found";
        case 500: return @"Internal Server Error";
        default:  return @"Unknown";
    }
}

/// 发送 HTTP 响应
/// 修复点：
///   1. Content-Length 使用 UTF-8 字节数（非 NSString.length 的 UTF-16 码元数）
///   2. send() 替换为 sendAll() 循环写入（处理部分写入）
///   3. 状态码 reason 正确映射（非 200 不再统一返回 "Internal Server Error"）
- (void)send:(int)client status:(int)status body:(NSString *)body type:(NSString *)type {
    NSString *reason = [self reasonForStatus:status];

    // 使用 UTF-8 字节数计算 Content-Length，解决非 ASCII 字符截断问题
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger bodyLen = bodyData ? bodyData.length : 0;

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        "Content-Type: %@\r\n"
        "Content-Length: %lu\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "\r\n",
        status, reason, type, (unsigned long)bodyLen];

    const char *hb = [header UTF8String];
    sendAll(client, hb, strlen(hb));

    if (bodyData && bodyLen > 0) {
        sendAll(client, bodyData.bytes, bodyLen);
    }
}

@end

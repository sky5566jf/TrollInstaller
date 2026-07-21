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

#define TI_PORT 8588

// ── iOS 私有 persona API：posix_spawn 提权为 root ──
// 参考 MatisuXCS TVNCHttpServer.mm spawnAsRoot 实现。
// supervisor 有 platform-application entitlement，可以调用这些 API。
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
 * LSApplicationWorkspace 在 App 与守护进程(daemon) 两种上下文都能打开 URL，
 * 不依赖 UIApplication，因此后台守护进程也能弹出巨魔安装框。
 * 仅在运行时通过 NSClassFromString 调用，无需链接私有框架，Linux 交叉编译也能过。
 */
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

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

- (void)runLoop {
    while (_running) {
        int client = accept(_listenSock, NULL, NULL);
        if (client < 0) {
            if (_running) continue;
            break;
        }
        @autoreleasepool {
            [self handleClient:client];
        }
        close(client);
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

    NSString *body = @"{\"status\":\"Matisu Troll Assistant API\",\"port\":8588}";
    [self send:client status:200 body:body type:@"application/json"];
}

#pragma mark - TrollStore Helper 查找

/// 查找 trollstorehelper 可执行文件路径
/// 参考 MatisuXCS TVNCApiManager trollStoreHelperPath 实现
/// iOS 安装路径是 UUID 格式（如 2AAEE097-D05A-...），不能用 bundle ID 直接拼
- (NSString *)findTrollStoreHelper {
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

            // 快速检测：目录名含 TrollStore/opa334，或目录下有 TrollStore.app
            BOOL isTrollStoreDir = ([uuidDir rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                    [uuidDir rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (isTrollStoreDir) {
                // 直接检查目录下的 trollstorehelper
                NSString *helper = [fullPath stringByAppendingPathComponent:@"trollstorehelper"];
                if (access([helper UTF8String], X_OK) == 0) {
                    NSLog(@"[HTTPServer] found trollstorehelper (UUID dir): %@", helper);
                    return helper;
                }
            }

            // 遍历子目录查找 TrollStore.app/trollstorehelper
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

/// 以 root 身份 spawn 进程并捕获 stdout/stderr 输出
/// 参考 MatisuXCS TVNCHttpServer.mm spawnAsRootWithOutput 实现
/// supervisor 有 platform-application entitlement，可使用 persona_np API
static int spawnAsRootWithOutput(NSString *path, NSArray *args, NSString **outputOut) {
    if (!path) return -1;

    NSMutableArray *fullArgv = [NSMutableArray arrayWithObject:path];
    if (args) [fullArgv addObjectsFromArray:args];

    char **argv = (char **)malloc((fullArgv.count + 1) * sizeof(char *));
    for (NSUInteger i = 0; i < fullArgv.count; i++) {
        argv[i] = (char *)[fullArgv[i] UTF8String];
    }
    argv[fullArgv.count] = NULL;

    // 创建 pipe 捕获 stdout/stderr
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

    // ── persona_np 提权 ──
    pid_t pid;
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) {
        NSLog(@"[HTTPServer] posix_spawnattr_init failed: %d", err);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (err != 0) {
        NSLog(@"[HTTPServer] set_persona_np failed: %d", err);
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (err != 0) {
        NSLog(@"[HTTPServer] set_persona_uid_np failed: %d", err);
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&actions);
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return err;
    }

    err = posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (err != 0) {
        NSLog(@"[HTTPServer] set_persona_gid_np failed: %d", err);
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

    // 关闭写端，开始读取子进程输出
    close(pipefd[1]);

    NSMutableData *outData = [NSMutableData data];
    char buf[4096];
    ssize_t nr;
    while ((nr = read(pipefd[0], buf, sizeof(buf))) > 0) {
        [outData appendBytes:buf length:(NSUInteger)nr];
    }
    close(pipefd[0]);

    // 等待子进程结束
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

#pragma mark - 下载 tipa 到临时文件

/// 下载 tipa 文件到 /tmp/matisu_install_<timestamp>.tipa
/// 使用 NSData dataWithContentsOfURL:（同步，适合本地网络小文件）
- (NSString *)downloadToTemp:(NSString *)urlString error:(NSString **)errorOut {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (errorOut) *errorOut = @"invalid_url";
        return nil;
    }

    NSLog(@"[HTTPServer] downloading tipa from: %@", urlString);

    NSError *nsErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&nsErr];
    if (!data || nsErr) {
        NSString *errMsg = nsErr ? nsErr.localizedDescription : @"no_data";
        NSLog(@"[HTTPServer] download failed: %@", errMsg);
        if (errorOut) *errorOut = [NSString stringWithFormat:@"download_failed: %@", errMsg];
        return nil;
    }

    NSLog(@"[HTTPServer] downloaded %lu bytes", (unsigned long)data.length);

    // 写入临时文件
    NSString *tempPath = [NSString stringWithFormat:@"/tmp/matisu_install_%lld.tipa",
                          (long long)(time(NULL))];
    if (![data writeToFile:tempPath atomically:YES]) {
        NSLog(@"[HTTPServer] write to temp failed: %@", tempPath);
        if (errorOut) *errorOut = @"write_temp_failed";
        return nil;
    }

    NSLog(@"[HTTPServer] saved tipa to: %@", tempPath);
    return tempPath;
}

#pragma mark - JSON 字符串安全转义

/// 简易 JSON 字符串转义：处理引号、反斜杠、换行等
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

/// 从 trollstorehelper 的输出日志中提取 bundle ID
/// 输出格式：[installApp] new app path: /path/to/UUID/BundleName.app
/// bundle ID 不等于 .app 文件夹名，需要从 Info.plist 读取或用 MCMAppContainer 信息
/// 但 trollstorehelper 输出中有 MCMAppContainer ID: <bundle_id> UUID: ...
/// 例如：ID: live.cclerc.geranium UUID: B4C3B19C-...
- (NSString *)extractBundleIdFromOutput:(NSString *)output {
    if (!output || output.length == 0) return nil;

    // 方法1: 从 MCMAppContainer ID 行提取
    // 格式: ID: live.cclerc.geranium UUID: ...
    NSRange idRange = [output rangeOfString:@"ID: "];
    if (idRange.location != NSNotFound) {
        NSString *afterId = [output substringFromIndex:idRange.location + 4];
        NSRange spaceRange = [afterId rangeOfString:@" "];
        if (spaceRange.location != NSNotFound && spaceRange.location > 0) {
            NSString *bundleId = [afterId substringToIndex:spaceRange.location];
            // 简单验证：bundle ID 应包含点号
            if ([bundleId containsString:@"."]) {
                NSLog(@"[HTTPServer] extracted bundleId from MCMAppContainer: %@", bundleId);
                return bundleId;
            }
        }
    }

    // 方法2: 从 new app path 提取 .app 目录名
    // 格式: [installApp] new app path: /path/UUID/Geranium.app
    NSRange pathRange = [output rangeOfString:@"[installApp] new app path: "];
    if (pathRange.location != NSNotFound) {
        NSString *afterPath = [output substringFromIndex:pathRange.location + 28];
        // 取最后一个路径组件（.app 目录名）
        NSArray *pathParts = [afterPath componentsSeparatedByString:@"\n"];
        if (pathParts.count > 0) {
            NSString *appPath = [pathParts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *appName = [appPath lastPathComponent]; // "Geranium.app"
            NSString *nameNoExt = [appName stringByDeletingPathExtension]; // "Geranium"
            NSLog(@"[HTTPServer] extracted app name (not bundleId): %@ — may not match bundle ID", nameNoExt);
            return nameNoExt;
        }
    }

    NSLog(@"[HTTPServer] cannot extract bundleId from trollstorehelper output");
    return nil;
}

#pragma mark - 启动已安装的 App

/// 以 root 身份 spawn supervisor 二进制的 --launch 模式来启动 App
/// supervisor 的 --launch 模式会 dlopen FrontBoard/SBS → FBSOpenApplication/SBSOpenURL → 启动 App → 退出
- (NSString *)launchApp:(NSString *)bundleId {
    // 获取自身二进制的绝对路径（supervisor 的 vnode 监控要求绝对路径运行）
    NSString *execPath = [[NSProcessInfo processInfo] arguments][0];
    if (!execPath || execPath.length == 0) {
        NSLog(@"[HTTPServer] cannot determine own executable path");
        return @"no_exec_path";
    }

    NSLog(@"[HTTPServer] launching app %@ via spawnAsRoot(%@ --launch %@)", bundleId, execPath, bundleId);

    // spawnAsRoot: matisusupervisor --launch <bundle_id>
    // 以 root 身份运行，root 能 dlopen FrontBoard/SBS → 启动 App
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

/// /install?url=<tipa_url>&launch=<bundle_id> 处理入口
/// 双路径策略：
///   1) trollstorehelper 直接安装（下载 tipa → spawnAsRoot → 静默安装）
///   2) openURL 兜底（SBS → LSApplicationWorkspace → 触发巨魔安装界面）
/// launch 参数：安装成功后自动启动 App（可选，支持多个）
///   格式：
///     /install?url=<tipa>&launch=com.app1              — 启动单个 App
///     /install?url=<tipa>&launch=com.app1,com.app2     — 启动多个 App（逗号分隔）
///     /install?url=<tipa>&launch=true                  — 自动从 tipa 解析 bundle ID 并启动
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
        // 去掉后面的 &launch=... 部分（如果有）
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

        // 下载 tipa 到 /tmp
        NSString *dlError = nil;
        NSString *tempPath = [self downloadToTemp:decoded error:&dlError];
        if (tempPath) {
            // spawnAsRoot: trollstorehelper install <tipa_path>
            NSString *output = nil;
            int exitCode = spawnAsRootWithOutput(helperPath,
                                                 @[@"install", tempPath],
                                                 &output);

            // 清理临时文件（无论成功失败都删）
            unlink([tempPath UTF8String]);

            NSString *statusStr = (exitCode == 0) ? @"ok" : @"error";
            NSString *escOutput = [self jsonEscape:output];
            NSString *escUrl = [self jsonEscape:decoded];

            // ── 安装成功后自动启动 App（支持多个 bundle ID，逗号分隔）──
            // launch=com.app1,com.app2,com.app3 → 依次启动多个 App
            // launch=true → 从 trollstorehelper 输出自动解析 bundle ID（单个）
            // launch=com.app1 → 单个（向后兼容）
            NSMutableArray *launchResultArray = [NSMutableArray array];
            if (exitCode == 0 && launchParam) {
                NSArray *bundleIds = nil;

                if ([launchParam isEqualToString:@"true"]) {
                    // 自动解析单个 bundle ID
                    NSString *autoBid = [self extractBundleIdFromOutput:output];
                    NSLog(@"[HTTPServer] auto-detected bundleId: %@", autoBid);
                    if (autoBid) bundleIds = @[autoBid];
                } else {
                    // 逗号分隔解析多个 bundle ID
                    bundleIds = [launchParam componentsSeparatedByString:@","];
                }

                NSLog(@"[HTTPServer] launching %lu app(s): %@", (unsigned long)bundleIds.count, bundleIds);

                NSUInteger launchIndex = 0;
                for (NSString *bid in bundleIds) {
                    NSString *trimmed = [bid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0) continue;

                    // 多 App 启动时，从第二个开始每个间隔 10 秒
                    if (launchIndex > 0) {
                        NSLog(@"[HTTPServer] waiting 10s before launching next app: %@", trimmed);
                        sleep(10);
                    }

                    NSString *result = [self launchApp:trimmed];
                    // 每个结果作为 JSON 对象加入数组
                    [launchResultArray addObject:[NSString stringWithFormat:
                        @"{\"bundleId\":\"%@\",\"result\":\"%@\"}",
                        [self jsonEscape:trimmed], [self jsonEscape:result]]];
                    launchIndex++;
                }

                if (launchResultArray.count == 0 && bundleIds.count == 0) {
                    [launchResultArray addObject:@"{\"bundleId\":\"\",\"result\":\"no_bundle_id\"}"];
                }
            }

            // launch 字段输出为 JSON 数组格式
            NSString *launchJson = [launchResultArray componentsJoinedByString:@","];

            NSString *body = [NSString stringWithFormat:
                @"{\"status\":\"%@\",\"url\":\"%@\",\"method\":\"trollstorehelper\",\"exitCode\":%d,\"output\":\"%@\",\"launch\":[%@]}",
                statusStr, escUrl, exitCode, escOutput, launchJson];
            [self send:client status:(exitCode == 0 ? 200 : 500) body:body type:@"application/json"];
            return;
        }

        // 下载失败，记录但继续尝试 openURL 兜底
        NSLog(@"[HTTPServer] download failed: %@, falling back to openURL", dlError);
    } else {
        NSLog(@"[HTTPServer] trollstorehelper not found, falling back to openURL");
    }

    // ── 路径2: openURL 兜底（触发巨魔安装界面）──
    NSString *scheme = [@"apple-magnifier://install?url=" stringByAppendingString:decoded];
    NSString *method = [self triggerInstall:scheme];

    NSString *escUrl = [self jsonEscape:decoded];
    NSString *escMethod = [self jsonEscape:method];
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"url\":\"%@\",\"method\":\"%@\"}", escUrl, escMethod];
    [self send:client status:200 body:body type:@"application/json"];
}

/// 触发巨魔安装 — 三级 fallback（仅作为兜底路径）：
///   1) SBSOpenSensitiveURLAndUnlockDevice（SpringBoardServices C 函数）
///   2) SBSOpenURL（同框架，不带解锁）
///   3) LSApplicationWorkspace openURL:（最后兜底）
/// 注意：守护进程中 SBS dlopen 可能失败（no-container 进程无法加载 shared cache framework），
///       LSApplicationWorkspace openURL: 在守护进程中静默失败。
///       因此 trollstorehelper 直接安装才是可靠方案。
- (NSString *)triggerInstall:(NSString *)scheme {
    NSURL *u = [NSURL URLWithString:scheme];
    if (!u) return @"invalid_url";

    // ── 方法1: SBSOpenSensitiveURLAndUnlockDevice ──
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

        // ── 方法2: SBSOpenURL ──
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
        // 记录 dlerror 以便诊断
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

- (void)send:(int)client status:(int)status body:(NSString *)body type:(NSString *)type {
    NSString *reason = (status == 200) ? @"OK" : @"Internal Server Error";
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        "Content-Type: %@\r\n"
        "Content-Length: %lu\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "\r\n",
        status, reason, type, (unsigned long)body.length];

    const char *hb = [header UTF8String];
    send(client, hb, (int)strlen(hb), 0);

    const char *bb = [body UTF8String];
    send(client, bb, (int)strlen(bb), 0);
}

@end

#import "HTTPServer.h"
#import <dispatch/dispatch.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>

#define TI_PORT 8588

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
            if (_running) continue;   // 被信号打断，继续等
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
    // 持续读取直到遇到请求头结束标志 \r\n\r\n
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
    NSString *target = parts[1]; // e.g. /install?url=...

    if ([target hasPrefix:@"/install"]) {
        [self handleInstall:client target:target];
        return;
    }

    // 其它路径：返回简单状态
    NSString *body = @"{\"status\":\"Matisu Troll Assistant API\",\"port\":8588}";
    [self send:client status:200 body:body type:@"application/json"];
}

- (void)handleInstall:(int)client target:(NSString *)target {
    NSString *query = @"";
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound && q.location + 1 < target.length) {
        query = [target substringFromIndex:q.location + 1];
    }

    // 取 url= 之后所有内容（兼容 tipa 地址自身携带 & 参数的情况）
    NSString *urlParam = @"";
    NSRange urlRange = [query rangeOfString:@"url="];
    if (urlRange.location != NSNotFound) {
        urlParam = [query substringFromIndex:urlRange.location + urlRange.length];
    }
    if (urlParam.length == 0) {
        NSString *body = @"{\"status\":\"error\",\"msg\":\"url required\"}";
        [self send:client status:400 body:body type:@"application/json"];
        return;
    }

    NSString *decoded = [urlParam stringByRemovingPercentEncoding] ?: urlParam;
    NSString *scheme = [@"apple-magnifier://install?url=" stringByAppendingString:decoded];

    NSURL *u = [NSURL URLWithString:scheme];
    if (!u) {
        NSString *body = @"{\"status\":\"error\",\"msg\":\"invalid url\"}";
        [self send:client status:400 body:body type:@"application/json"];
        return;
    }

    NSString *method = [self triggerInstall:scheme];

    NSString *body = [NSString stringWithFormat:@"{\"status\":\"ok\",\"url\":\"%@\",\"method\":\"%@\"}", decoded, method];
    [self send:client status:200 body:body type:@"application/json"];
}

/// 触发巨魔安装 — 三级 fallback：
///   1) SBSOpenSensitiveURLAndUnlockDevice（SpringBoardServices C 函数，守护进程可用）
///   2) SBSOpenURL（同框架，不带解锁）
///   3) LSApplicationWorkspace openURL:（最后兜底）
/// 参考 MatisuXCS openURLViaSBS: 实现。
- (NSString *)triggerInstall:(NSString *)scheme {
    NSURL *u = [NSURL URLWithString:scheme];
    if (!u) return @"invalid_url";

    // ── 方法1: SBSOpenSensitiveURLAndUnlockDevice ──
    // 直接通过 SpringBoardServices Mach 消息与 SpringBoard 通信，
    // 守护进程也能用，需要 com.apple.springboard.opensensitiveurl entitlement。
    void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbsHandle) {
        // SBSOpenSensitiveURLAndUnlockDevice(CFURLRef url, int flags)
        typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef url, int flags);
        SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
        if (openSensitive) {
            @try {
                openSensitive((__bridge CFURLRef)u, 1);
                NSLog(@"[HTTPServer] SBSOpenSensitiveURLAndUnlockDevice OK: %@", scheme);
                dlclose(sbsHandle);
                return @"SBSOpenSensitiveURL";
            } @catch (NSException *e) {
                NSLog(@"[HTTPServer] SBSOpenSensitiveURL exception: %@", e);
            }
        }

        // ── 方法2: SBSOpenURL ──
        typedef void (*SBSOpenURLFunc)(CFURLRef url);
        SBSOpenURLFunc openURL = (SBSOpenURLFunc)dlsym(sbsHandle, "SBSOpenURL");
        if (openURL) {
            @try {
                openURL((__bridge CFURLRef)u);
                NSLog(@"[HTTPServer] SBSOpenURL OK: %@", scheme);
                dlclose(sbsHandle);
                return @"SBSOpenURL";
            } @catch (NSException *e) {
                NSLog(@"[HTTPServer] SBSOpenURL exception: %@", e);
            }
        }
        dlclose(sbsHandle);
    } else {
        NSLog(@"[HTTPServer] dlopen SpringBoardServices failed: %s", dlerror());
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
    NSString *reason = (status == 200) ? @"OK" : @"Bad Request";
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

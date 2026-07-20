#import "HTTPServer.h"
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

#define TI_PORT 8588

@implementation HTTPServer {
    BOOL _running;
}

+ (instancetype)sharedServer {
    static HTTPServer *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[HTTPServer alloc] init]; });
    return s;
}

- (void)start {
    if (_running) return;
    _running = YES;
    [NSThread detachNewThreadSelector:@selector(runLoop) toTarget:self withObject:nil];
}

- (void)runLoop {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { _running = NO; return; }

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TI_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        _running = NO;
        return;
    }
    if (listen(sock, 16) < 0) {
        close(sock);
        _running = NO;
        return;
    }

    while (_running) {
        int client = accept(sock, NULL, NULL);
        if (client < 0) continue;
        @autoreleasepool {
            [self handleClient:client];
        }
        close(client);
    }
    close(sock);
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
    NSString *body = @"{\"status\":\"TrollInstaller API\",\"port\":8588}";
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

    // openURL 必须在主线程调用
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    });

    NSString *body = [NSString stringWithFormat:@"{\"status\":\"ok\",\"url\":\"%@\"}", decoded];
    [self send:client status:200 body:body type:@"application/json"];
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

#import "AppDelegate.h"
#import "ViewController.h"
#import "HTTPServer.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 自启动：App 一进前台即拉起 HTTP 服务，监听 0.0.0.0:8588
    [[HTTPServer sharedServer] start];

    return YES;
}

@end

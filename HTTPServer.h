#import <Foundation/Foundation.h>

@interface HTTPServer : NSObject
+ (instancetype)sharedServer;
- (void)start;
@end

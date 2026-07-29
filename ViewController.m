#import "ViewController.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 标题「M巨魔助手」
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"M巨魔助手";
    title.numberOfLines = 0;
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor labelColor];
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    [self.view addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-14],
    ]];

    // 版本号（从 Info.plist 动态读取，随发版自动更新）
    NSString *version = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.text = [NSString stringWithFormat:@"v%@", version];
    versionLabel.numberOfLines = 1;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.textColor = [UIColor secondaryLabelColor];
    versionLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.view addSubview:versionLabel];
    [NSLayoutConstraint activateConstraints:@[
        [versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [versionLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
    ]];
}

@end

#import "ViewController.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 界面只显示「Matisu巨魔助手」
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Matisu巨魔助手";
    title.numberOfLines = 0;
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor labelColor];
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    [self.view addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end

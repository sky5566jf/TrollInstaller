ARCHS = arm64
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

# ---- 主 App（前台 UI + posix_spawn 拉起 supervisor）----
APPLICATION_NAME = TrollInstaller
TrollInstaller_FILES = main.m AppDelegate.m ViewController.m HTTPServer.m
TrollInstaller_CFLAGS = -fobjc-arc
TrollInstaller_FRAMEWORKS = UIKit Foundation
TrollInstaller_RESOURCES = AppIcon.png
TrollInstaller_ENTITLEMENTS = Entitlements.plist
TrollInstaller_INFOPLIST_PATH = Info.plist

# ---- 常驻监督器(resident supervisor) ----
# 纯 TrollStore 非越狱下实现"App 划掉后 API 继续"的核心：
#   setsid() 脱离 App 进程组 + 忽略 SIGHUP/SIGTERM → App 死 supervisor 不死
# 参考 TrollVNC trollvncmanager 的 resident supervisor 模式
TOOL_NAME = matisusupervisor
matisusupervisor_FILES = supervisor_main.m HTTPServer.m
matisusupervisor_CFLAGS = -fobjc-arc -DTHEBOOTSTRAP=1
matisusupervisor_FRAMEWORKS = Foundation
matisusupervisor_ENTITLEMENTS = supervisor.entitlements

include $(THEOS)/makefiles/application.mk
include $(THEOS)/makefiles/tool.mk

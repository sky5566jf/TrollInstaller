ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

# ---- 主 App（前台 + UI）----
APPLICATION_NAME = TrollInstaller
TrollInstaller_FILES = main.m AppDelegate.m ViewController.m HTTPServer.m
TrollInstaller_CFLAGS = -fobjc-arc
TrollInstaller_FRAMEWORKS = UIKit Foundation
TrollInstaller_RESOURCES = AppIcon.png com.matisu.trollserver.plist
TrollInstaller_ENTITLEMENTS = Entitlements.plist
TrollInstaller_INFOPLIST_PATH = Info.plist

# ---- 常驻守护进程（后台服务，独立二进制，由 launchd 拉起）----
TOOL_NAME = trollserver
trollserver_FILES = daemon_main.m HTTPServer.m
trollserver_CFLAGS = -fobjc-arc
trollserver_FRAMEWORKS = Foundation
trollserver_INSTALL_PATH = /Applications/TrollInstaller.app

include $(THEOS)/makefiles/application.mk

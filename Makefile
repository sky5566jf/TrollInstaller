ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollInstaller
TrollInstaller_FILES = main.m AppDelegate.m ViewController.m HTTPServer.m
TrollInstaller_CFLAGS = -fobjc-arc
TrollInstaller_FRAMEWORKS = UIKit Foundation
TrollInstaller_RESOURCES = AppIcon.png
TrollInstaller_ENTITLEMENTS = Entitlements.plist
TrollInstaller_INFOPLIST_PATH = Info.plist

include $(THEOS)/makefiles/application.mk

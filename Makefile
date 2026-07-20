ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

APP_NAME = TrollInstaller
$(APP_NAME)_FILES = main.m AppDelegate.m ViewController.m HTTPServer.m
$(APP_NAME)_CFLAGS = -fobjc-arc
$(APP_NAME)_FRAMEWORKS = UIKit Foundation
$(APP_NAME)_RESOURCES = AppIcon.png
$(APP_NAME)_ENTITLEMENTS = Entitlements.plist
$(APP_NAME)_INFOPLIST_PATH = Info.plist

include $(THEOS)/makefiles/application.mk

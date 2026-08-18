# QQFloatBall — QQ悬浮球（roothide）
export ARCHS = arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQFloatBall

QQFloatBall_FILES = Tweak.xm
QQFloatBall_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
QQFloatBall_LDFLAGS = -Wl,-fixup_chains -framework CydiaSubstrate -F"$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide" -lroothide

include $(THEOS_MAKE_PATH)/tweak.mk

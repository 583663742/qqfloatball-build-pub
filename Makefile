# QQFloatBall — QQ悬浮球（roothide）
export ARCHS = arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQFloatBall

QQFloatBall_FILES = Tweak.xm
QQFloatBall_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-retain-cycles -nostdinc++ -isystem "$(THEOS_SDK_PATH)/usr/include/c++/v1"
QQFloatBall_LDFLAGS = -fuse-ld=lld -L"$(THEOS_SDK_PATH)/usr/lib" -Wl,-fixup_chains -framework CydiaSubstrate -F"$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide" -lroothide
# ⚠️ 签名是标准流程：禁止 TARGET_CODESIGN=true（无签名→ellekit 1.2 拒载→球消失，2026-08-19 实锤）
export TARGET_STRIP = true

include $(THEOS_MAKE_PATH)/tweak.mk

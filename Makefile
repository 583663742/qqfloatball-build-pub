# QQFloatBall — QQ悬浮球（roothide）
# ⚠️ 2026-08-28 关键修复：必须编译 fat 二进制（arm64 + arm64e）。
#    只编译 arm64e 时，TrollStore 注入器无法处理 PAC 签名，dyld 校验失败→QQ闪退。
#    能注入生效的插件（通用破解内购=arm64 / 王跳跳=arm64+arm64e fat）都有 arm64 切片。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQFloatBall

QQFloatBall_FILES = Tweak.xm
QQFloatBall_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-retain-cycles -nostdinc++ -isystem "$(THEOS_SDK_PATH)/usr/include/c++/v1"
QQFloatBall_LDFLAGS = -L"$(THEOS_SDK_PATH)/usr/lib" -framework CydiaSubstrate -F"$(THEOS_VENDOR_LIBRARY_PATH)/iphone/roothide" -lroothide
# ⚠️ 签名是标准流程：禁止 TARGET_CODESIGN=true（无签名→ellekit 1.2 拒载→球消失，2026-08-19 实锤）
# ⚠️ 链接器必须真 Apple ld64（arm64-apple-darwin-ld / theos toolchain ld.exe, md5 016b3a02）：
#    - 禁止 -fuse-ld=lld（mingw lld 不支持 darwin 目标）
#    - 禁止 -Wl,-fixup_chains（触发 ld64 错位 bug：cmdsize 差 1 字节→dyld 拒载；arm64e 默认即 chained fixups）
export TARGET_STRIP = true

include $(THEOS_MAKE_PATH)/tweak.mk

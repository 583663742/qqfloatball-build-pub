# QQFloatBall — QQ悬浮球（TrollStore 兼容布局）
# ⚠️ 2026-08-30 关键修复：去掉 roothide scheme + roothide 链接，让产物走 @executable_path/libsubstrate.dylib。
#    对照参考物（王跳跳_1.1.dylib / 通用破解内购和去广告.dylib）：
#    - LOAD_DYLIB 全部走 @executable_path/libsubstrate.dylib（单一路径）
#    - 无 roothide 依赖
#    - TrollStore 注入器把这个路径改写到 QQ.app 容器内实际位置
#    插件源码不使用 roothide API，去掉链接是安全的。
#
# ⚠️ 必须编译 fat 二进制（arm64 + arm64e）。只编译 arm64e 时 TrollStore 注入器无法处理 PAC 签名，dyld 校验失败→QQ闪退。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:17.0

INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQFloatBall

QQFloatBall_FILES = Tweak.xm
QQFloatBall_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-retain-cycles -nostdinc++ -isystem "$(THEOS_SDK_PATH)/usr/include/c++/v1"
QQFloatBall_LDFLAGS = -L"$(THEOS_SDK_PATH)/usr/lib" -framework CydiaSubstrate
# ⚠️ 签名是标准流程：禁止 TARGET_CODESIGN=true（无签名→ellekit 1.2 拒载→球消失，2026-08-19 实锤）
# ⚠️ 链接器必须真 Apple ld64（arm64-apple-darwin-ld / theos toolchain ld.exe, md5 016b3a02）：
#    - 禁止 -fuse-ld=lld（mingw lld 不支持 darwin 目标）
#    - 禁止 -Wl,-fixup_chains（触发 ld64 错位 bug：cmdsize 差 1 字节→dyld 拒载；arm64e 默认即 chained fixups）
export TARGET_STRIP = true

include $(THEOS_MAKE_PATH)/tweak.mk

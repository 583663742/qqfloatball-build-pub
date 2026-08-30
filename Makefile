# QQFloatBall — QQ悬浮球（TrollFools 注入路线 2026-08-30 定案：只用 TrollFools，不用 Sileo/TrollStore本体）
# fat arm64+arm64e（TrollFools 支持 fat）
# ★ 依赖必须走标准 CydiaSubstrate.framework（TrollFools 自带 ellekit 伪装版替代 substrate，注入时自动补）
#   ❌ 不能用 roothide scheme（依赖 @loader_path/.jbroot/usr/lib/libsubstrate.dylib，TrollFools 不建 .jbroot → dyld 加载闪退）
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQFloatBall

QQFloatBall_FILES = Tweak.xm
QQFloatBall_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-retain-cycles -nostdinc++ -isystem "$(THEOS_SDK_PATH)/usr/include/c++/v1"
QQFloatBall_LDFLAGS = -framework CydiaSubstrate
# ⚠️ 签名是标准流程：禁止 TARGET_CODESIGN=true（无签名→ellekit 拒载→球消失，2026-08-19 实锤）
# ⚠️ 链接器必须真 Apple ld64（arm64-apple-darwin-ld / theos toolchain ld.exe, md5 016b3a02）：
#    - 禁止 -fuse-ld=lld（mingw lld 不支持 darwin 目标）
#    - 禁止 -Wl,-fixup_chains（触发 ld64 错位 bug：cmdsize 差 1 字节→dyld 拒载；arm64e 默认即 chained fixups）
export TARGET_STRIP = true

include $(THEOS_MAKE_PATH)/tweak.mk

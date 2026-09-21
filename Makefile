TARGET = iphone:clang:16.5:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = ShellPlayer

APPLICATION_NAME = ShellPlayer
ShellPlayer_FILES = main.m
ShellPlayer_FRAMEWORKS = UIKit AVKit AVFoundation CoreGraphics Foundation UniformTypeIdentifiers
ShellPlayer_CFLAGS = -fobjc-arc
ShellPlayer_CODESIGN_FLAGS = -S

include $(THEOS)/makefiles/common.mk

include $(THEOS_MAKE_PATH)/application.mk

# 打包成可安装的 .ipa（放进 .deb 里捎带出去）
after-install::
	@echo "==> 组装 IPA"
	@rm -rf "$(THEOS_PROJECT_DIR)/out"
	@mkdir -p "$(THEOS_PROJECT_DIR)/out/Payload" "$(THEOS_STAGING_DIR)/usr/share"
	@cp -R "$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app" "$(THEOS_PROJECT_DIR)/out/Payload/"
	@cd "$(THEOS_PROJECT_DIR)/out" && zip -qry "$(APPLICATION_NAME).ipa" Payload
	@cp "$(THEOS_PROJECT_DIR)/out/$(APPLICATION_NAME).ipa" "$(THEOS_STAGING_DIR)/usr/share/"
	@echo "==> IPA 产物："
	@ls -la "$(THEOS_PROJECT_DIR)/out"
	@otool -L "$(THEOS_PROJECT_DIR)/out/Payload/$(APPLICATION_NAME).app/$(APPLICATION_NAME)" || true

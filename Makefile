SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
MAC := $(ROOT)/mac
ANDROID := $(ROOT)/android
APP := $(ROOT)/build/.Mirage.app
JAVA_HOME ?=
JDK17 := $(firstword $(wildcard $(HOME)/Library/Java/JavaVirtualMachines/*17*/Contents/Home /Library/Java/JavaVirtualMachines/*17*/Contents/Home))
JDK21 := $(firstword $(wildcard $(HOME)/Library/Java/JavaVirtualMachines/*21*/Contents/Home /Library/Java/JavaVirtualMachines/*21*/Contents/Home))
GRADLE_JAVA_HOME := $(if $(JDK17),$(JDK17),$(if $(JDK21),$(JDK21),$(JAVA_HOME)))
ANDROID_HOME ?=
ADB ?= adb
INSTALL_DIR ?= /Applications
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ && !/CSSMERR/ {print $$2; exit}')
DEVICE ?= $(shell $(ADB) devices 2>/dev/null | awk 'NR>1 && $$2=="device" {print $$1; exit}')
PORT ?= 7777
HARMONY := $(ROOT)/harmony
DEVECO_HOME ?= /Applications/DevEco-Studio.app
HVIGORW := $(DEVECO_HOME)/Contents/tools/hvigor/bin/hvigorw
HARMONY_ENV := JAVA_HOME=$(DEVECO_HOME)/Contents/jbr/Contents/Home DEVECO_SDK_HOME=$(DEVECO_HOME)/Contents/sdk
HDC ?= $(DEVECO_HOME)/Contents/sdk/default/openharmony/toolchains/hdc
HDC_DEVICE ?= $(shell $(HDC) list targets 2>/dev/null | head -1)
HDC_T := $(if $(HDC_DEVICE),-t $(HDC_DEVICE),)
HAP := $(HARMONY)/entry/build/default/outputs/default/entry-default-signed.hap
TEST_HAP := $(HARMONY)/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap

.PHONY: help init build build-mac build-android build-aoa build-harmony app test test-harmony clean install install-mac install-apk install-hap connect connect-harmony run dev logs

help:
	@echo "Mirage 常用命令:"
	@echo "  make init          检查并初始化开发环境"
	@echo "  make build         构建 Mac 端、AOA 桥接、Android APK 和鸿蒙 HAP"
	@echo "  make app           打包 build/Mirage.app"
	@echo "  make test          运行 Mac、Android 与鸿蒙单元测试"
	@echo "  make install       安装 App 到 $(INSTALL_DIR)，并安装 APK/HAP 到设备"
	@echo "  make connect       adb 连接 Android 设备并设置端口反向转发"
	@echo "  make connect-harmony  hdc 设置端口反向转发（TCP 模式）"
	@echo "  make run           打开已打包的 Mirage.app"
	@echo "  make dev           直接从源码运行菜单栏 App"
	@echo "  make logs          跟踪 helper 日志"
	@echo "  make clean         清理构建产物"

init:
	@command -v swift >/dev/null || { echo "缺少 Swift/Xcode 命令行工具"; exit 1; }
	@command -v ffmpeg >/dev/null || echo "提示: 未找到 ffmpeg（仅生成测试码流时需要）"
	@LIBUSB="$$(brew --prefix libusb 2>/dev/null)"; \
	if [ -z "$$LIBUSB" ]; then echo "提示: AOA USB 需要 libusb，执行 brew install libusb"; fi
	@if [ -n "$(GRADLE_JAVA_HOME)" ]; then \
		V=$$("$(GRADLE_JAVA_HOME)/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $$2}' | cut -d. -f1); \
		echo "Gradle JDK: $(GRADLE_JAVA_HOME) (Java $$V)"; \
		if [ -n "$$V" ] && { [ "$$V" -lt 17 ] || [ "$$V" -ge 25 ]; }; then \
			echo "错误: Gradle/AGP 需要 Java 17-24（推荐 17），当前 $$V"; exit 1; \
		fi; \
	else \
		echo "未找到 JDK 17/21，请安装并设置 JAVA_HOME"; \
	fi
	@if [ ! -f $(ANDROID)/local.properties ] && [ -n "$(ANDROID_HOME)" ]; then \
		echo "sdk.dir=$(ANDROID_HOME)" > $(ANDROID)/local.properties; \
		echo "已写入 android/local.properties"; \
	fi
	@if [ ! -f $(ANDROID)/local.properties ]; then echo "提示: 请设置 ANDROID_HOME 或在 android/local.properties 写入 sdk.dir"; fi
	@cd $(MAC) && swift build
	@echo "初始化完成"

build: build-mac build-android build-aoa build-harmony

build-mac:
	cd $(MAC) && swift build

build-aoa:
	@LIBUSB="$$(brew --prefix libusb 2>/dev/null)"; \
	if [ -z "$$LIBUSB" ]; then echo "缺少 libusb：brew install libusb"; exit 1; fi; \
	mkdir -p $(ROOT)/build; \
	cc -O2 -I"$$LIBUSB/include/libusb-1.0" $(ROOT)/tools/aoa_bridge.c \
		"$$LIBUSB/lib/libusb-1.0.a" \
		-framework IOKit -framework CoreFoundation -framework Security -pthread \
		-o $(ROOT)/build/aoa_bridge

build-android:
	cd $(ANDROID) && JAVA_HOME="$(GRADLE_JAVA_HOME)" ./gradlew :app:assembleDebug

build-harmony:
	@test -x "$(HVIGORW)" || { echo "未找到 hvigorw：设置 DEVECO_HOME 指向 DevEco Studio 安装目录"; exit 1; }
	cd $(HARMONY) && $(HARMONY_ENV) $(HVIGORW) assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

app:
	SIGN_IDENTITY="$(SIGN_IDENTITY)" bash $(ROOT)/tools/build_app.sh

test:
	cd $(MAC) && swift test
	cd $(ANDROID) && JAVA_HOME="$(GRADLE_JAVA_HOME)" ./gradlew :app:testDebugUnitTest
	$(MAKE) test-harmony

test-harmony:
	@test -x "$(HVIGORW)" || { echo "未找到 hvigorw：设置 DEVECO_HOME 指向 DevEco Studio 安装目录"; exit 1; }
	cd $(HARMONY) && $(HARMONY_ENV) $(HVIGORW) assembleHap --mode module -p product=default -p buildMode=debug -p module=entry@ohosTest --no-daemon
	@if [ -z "$(HDC_DEVICE)" ]; then echo "没有已连接鸿蒙设备，跳过单测运行"; exit 0; fi
	$(HDC) $(HDC_T) install -r $(TEST_HAP)
	@out=$$($(HDC) $(HDC_T) shell "aa test -b app.mirage.harmony -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 60000" 2>&1); \
		echo "$$out"; \
		echo "$$out" | grep -q 'Failure: 0, Error: 0' || { echo "鸿蒙单测失败"; exit 1; }

clean:
	cd $(MAC) && swift package clean
	rm -rf $(ROOT)/build $(ANDROID)/app/build $(ANDROID)/.gradle $(ANDROID)/.kotlin
	rm -rf $(HARMONY)/entry/build $(HARMONY)/.hvigor

install: install-mac install-apk install-hap

install-mac: app
	rm -rf "$(INSTALL_DIR)/Mirage.app"
	ditto "$(APP)" "$(INSTALL_DIR)/Mirage.app"
	@echo "已安装到 $(INSTALL_DIR)/Mirage.app"

install-apk: build-android
	@DEV="$(DEVICE)"; \
	if [ -z "$$DEV" ]; then echo "没有已连接设备，跳过 APK 安装"; exit 0; fi; \
	$(ADB) -s $$DEV install -r $(ANDROID)/app/build/outputs/apk/debug/app-debug.apk

install-hap: build-harmony
	@if [ -z "$(HDC_DEVICE)" ]; then echo "没有已连接鸿蒙设备，跳过 HAP 安装"; exit 0; fi
	$(HDC) $(HDC_T) install -r $(HAP)

connect:
	@DEV="$(DEVICE)"; \
	if [ -z "$$DEV" ]; then DEV=$$($(ADB) devices | awk 'NR>1 && $$2=="device" {print $$1; exit}'); fi; \
	if [ -z "$$DEV" ]; then \
		echo "没有已连接的 Android 设备（USB 调试请确认已开启；BlueStacks 可先执行 adb connect 127.0.0.1:5555）"; \
		exit 1; \
	fi; \
	$(ADB) -s $$DEV reverse tcp:7777 tcp:7777 && echo "adb reverse 已设置 ($$DEV)"

connect-harmony:
	@if [ -z "$(HDC_DEVICE)" ]; then \
		echo "hdc 未发现设备（模拟器先启动，或确认已 USB 调试授权）"; \
		exit 1; \
	fi
	$(HDC) $(HDC_T) rport tcp:$(PORT) tcp:$(PORT) && echo "hdc rport 已设置 ($(HDC_DEVICE):$(PORT))"

run:
	@if [ ! -d "$(APP)" ]; then $(MAKE) app; fi
	open "$(APP)"

dev:
	cd $(MAC) && swift run mirage-menu

logs:
	tail -f $(HOME)/Library/Logs/Mirage/helper.log
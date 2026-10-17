SCHEME := Edgely
BUILD_DIR := build
ARCHIVE_PATH := $(BUILD_DIR)/Edgely.xcarchive
EXPORT_PATH := $(BUILD_DIR)/export
EXPORT_OPTIONS := ExportOptions.plist
SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro

# App Store Connect API 密钥凭证，不进版本管理。config.mk 里设置 ASC_KEY_ID 和 ASC_ISSUER_ID，
# 并把 AuthKey_<ASC_KEY_ID>.p8 放在同一目录。
-include appstoreconnect/config.mk

APP_STORE_CONNECT_KEY_ID ?= $(ASC_KEY_ID)
APP_STORE_CONNECT_ISSUER_ID ?= $(ASC_ISSUER_ID)
APP_STORE_CONNECT_KEY_PATH ?= $(abspath appstoreconnect/AuthKey_$(ASC_KEY_ID).p8)

IN_GIT_REPO := $(shell git rev-parse --is-inside-work-tree 2>/dev/null)

ifeq ($(IN_GIT_REPO),true)
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null)
GIT_DIRTY := $(shell git status --porcelain 2>/dev/null)
GIT_TAG := $(shell git describe --tags --exact-match 2>/dev/null)
ifneq ($(strip $(GIT_DIRTY)),)
RELEASE_VERSION := $(GIT_HASH)+
else ifneq ($(strip $(GIT_TAG)),)
RELEASE_VERSION := $(patsubst v%,%,$(GIT_TAG))
else
RELEASE_VERSION := $(GIT_HASH)
endif
else
RELEASE_VERSION :=
endif

BUILD_NUMBER := $(shell date +%Y%m%d%H)

.PHONY: proj generate test build release clean

# 生成 Edgely.xcodeproj（带不带设备实现包由 scripts/gen_proj.sh 检测）
proj:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen 未安装，请先执行: brew install xcodegen"; exit 1; }
	./scripts/gen_proj.sh

generate: proj

test: proj
	xcodebuild test \
		-project Edgely.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(SIMULATOR)'

build: proj
	xcodebuild build \
		-project Edgely.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(SIMULATOR)'

# 归档并上传到 App Store Connect（ExportOptions.plist 的 destination 为 upload）
release: proj
	@test -n "$(APP_STORE_CONNECT_KEY_ID)" -a -n "$(APP_STORE_CONNECT_ISSUER_ID)" -a -f "$(APP_STORE_CONNECT_KEY_PATH)" || { \
		echo "缺少 App Store Connect 凭证：请在 appstoreconnect/config.mk 设置 ASC_KEY_ID、ASC_ISSUER_ID，并放入 AuthKey_<ASC_KEY_ID>.p8"; exit 1; }
	@echo "Marketing Version: $(RELEASE_VERSION)"
	@echo "Build Number: $(BUILD_NUMBER)"
	xcodebuild archive \
		-project Edgely.xcodeproj \
		-scheme $(SCHEME) \
		-archivePath $(ARCHIVE_PATH) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		-authenticationKeyPath "$(APP_STORE_CONNECT_KEY_PATH)" \
		-authenticationKeyID "$(APP_STORE_CONNECT_KEY_ID)" \
		-authenticationKeyIssuerID "$(APP_STORE_CONNECT_ISSUER_ID)" \
		MARKETING_VERSION="$(RELEASE_VERSION)" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)"
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportPath $(EXPORT_PATH) \
		-exportOptionsPlist $(EXPORT_OPTIONS) \
		-allowProvisioningUpdates \
		-authenticationKeyPath "$(APP_STORE_CONNECT_KEY_PATH)" \
		-authenticationKeyID "$(APP_STORE_CONNECT_KEY_ID)" \
		-authenticationKeyIssuerID "$(APP_STORE_CONNECT_ISSUER_ID)"

clean:
	rm -rf $(BUILD_DIR) Generated Edgely.xcodeproj

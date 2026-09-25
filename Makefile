SHELL := /bin/sh
CC ?= cc
TOUCH_DIR := touchscreen-control-center
TIMEKEEPER_DIR := timekeeper
BUILD_DIR := build
POSIX_DIRS := mihomo-manager mihomo-netns touchscreen-control-center \
	timekeeper mwan3-tuning web-full-menu vendor-control tests firmware luci-admin
SHELLCHECK_DIRS := $(POSIX_DIRS) zwrt-datad-tools
UNAME_S := $(shell uname -s)
TOUCH_LIBS := -pthread
TOUCH_LDFLAGS :=
TIMEKEEPER_LIBS :=
ifeq ($(UNAME_S),Linux)
TOUCH_LIBS += -ldl
TOUCH_LDFLAGS += -Wl,-soname,touchui-hook.so
TIMEKEEPER_LIBS += -ldl
endif

.PHONY: check shell-check shellcheck node-check boot-hook-check timekeeper-check touchui-check clean

check: shell-check shellcheck node-check boot-hook-check timekeeper-check touchui-check firmware-check luci-check

shell-check:
	@find $(POSIX_DIRS) -type f \
		\( -name '*.sh' -o -name '*.init' -o -name '*.api' \) \
		-exec sh -n {} \;
	@bash -n zwrt-datad-tools/update-zwrt-datad.sh

shellcheck:
	@command -v shellcheck >/dev/null
	@find $(SHELLCHECK_DIRS) -type f \
		\( -name '*.sh' -o -name '*.init' -o -name '*.api' \) \
		-print0 | xargs -0 shellcheck -S warning

node-check:
	@node --check mihomo-manager/patch-webui.mjs
	@node --check web-full-menu/patch-webui.mjs
	@node --test mihomo-manager/tests/*.test.mjs
	@node --test web-full-menu/tests/*.test.mjs

boot-hook-check:
	@./tests/boot-hooks.sh

timekeeper-check:
	@mkdir -p $(BUILD_DIR)
	$(CC) -Os -Wall -Wextra -Werror -o $(BUILD_DIR)/clock-event-test $(TIMEKEEPER_DIR)/test-clock-event.c -lm
	$(BUILD_DIR)/clock-event-test
	python3 $(TIMEKEEPER_DIR)/test_timekeeper.py
	@mkdir -p $(BUILD_DIR)
	$(CC) -std=c11 -Os -Wall -Wextra -Werror \
		-o $(BUILD_DIR)/time-genoff-host $(TIMEKEEPER_DIR)/time-genoff.c \
		$(TIMEKEEPER_LIBS)

touchui-check:
	@mkdir -p $(BUILD_DIR)
	$(CC) -shared -fPIC -Os -Wall -Wextra -Werror \
		$(TOUCH_LDFLAGS) \
		-o $(BUILD_DIR)/touchui-hook.so $(TOUCH_DIR)/touchui-hook.c $(TOUCH_LIBS)
	$(CC) -std=c11 -Os -Wall -Wextra -Werror -Wno-unused-function \
		-o $(BUILD_DIR)/json-key-match-test $(TOUCH_DIR)/tests/json-key-match.c
	$(BUILD_DIR)/json-key-match-test
	$(CC) -Os -Wall -Wextra -Werror \
		-o $(BUILD_DIR)/state-compat-test $(TOUCH_DIR)/tests/state-compat.c $(TOUCH_LIBS)
	$(BUILD_DIR)/state-compat-test

clean:
	@find $(BUILD_DIR) -type f -delete 2>/dev/null || true

.PHONY: luci-check
luci-check:
	python3 -m py_compile luci-admin/build.py luci-admin/manage.py luci-admin/change-password.py
	python3 -m unittest discover -s luci-admin/tests -v
	@for source in luci-admin/*.js luci-admin/views/*.js; do node --check "$$source"; done

.PHONY: firmware-check
firmware-check:
	sh -n firmware/b22/root-migration/90-mu5252-b22-root
	sh -n firmware/b22/root-migration/adb_shell
	shellcheck -S warning firmware/b22/root-migration/90-mu5252-b22-root firmware/b22/root-migration/adb_shell
	python3 -m py_compile firmware/b22/root-migration/prepare.py

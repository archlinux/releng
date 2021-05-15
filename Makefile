#
# SPDX-License-Identifier: GPL-3.0-or-later

all: build

check: lint

lint:
	shellcheck -s bash $(wildcard .gitlab/ci/*.sh)

build:
	./.gitlab/ci/build_releng.sh

.PHONY: build check lint

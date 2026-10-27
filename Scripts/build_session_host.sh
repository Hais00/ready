#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/Build"
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O2 -g -arch arm64 \
  -mmacosx-version-min=14.0 "$ROOT/SessionHost/ReadySessionHost.c" -o "$ROOT/Build/ReadySessionHost"
codesign --force --sign - "$ROOT/Build/ReadySessionHost"
printf '%s\n' "Built native ReadySessionHost in $ROOT/Build"

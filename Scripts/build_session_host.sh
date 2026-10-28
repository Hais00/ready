#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/Build"
STAGE=$(mktemp -d "$ROOT/Build/.ready-session-host-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# Never truncate or re-sign a helper inode that may hold a live session lease.
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O2 -g -arch arm64 \
  -mmacosx-version-min=14.0 "$ROOT/SessionHost/ReadySessionHost.c" "$ROOT/SessionHost/InstallationLease.c" -o "$STAGE/ReadySessionHost"
codesign --force --sign - "$STAGE/ReadySessionHost"
mv -f "$STAGE/ReadySessionHost" "$ROOT/Build/ReadySessionHost"
printf '%s\n' "Built native ReadySessionHost in $ROOT/Build"

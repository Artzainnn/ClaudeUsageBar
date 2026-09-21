#!/bin/bash
# Compiles the assert-based test mains and runs them. No SPM and no XCTest on
# purpose: build.sh stays untouched and this runs in seconds with nothing
# installed. Both targets must pass; set -e fails the script on the first that
# does not.
set -e
cd "$(dirname "$0")/.."
DIR="$(mktemp -d)"

# Target 1: the Foundation-only logic — thresholds, payload parsing, and the
# migration function itself.
swiftc -o "$DIR/cub-tests" UsageLogic.swift tests/support.swift tests/main.swift
"$DIR/cub-tests"

# Target 2: the slot invariants, which need the manager and the store compiled
# in. Above all "the migration runs before any manager reads its cookie" —
# target 1 stays green no matter where that call sits.
#
# MenuBarIcon.swift rides along because it already links AppKit here and the
# icon is a pure function: the badge's clearances are hand-tuned constants that
# nothing else would catch drifting.
#
# -suppress-warnings: this target recompiles UsageManager.swift, whose ~30
# NSUserNotification deprecations would bury a FAIL line on every run. build.sh
# is where warnings on app sources get reviewed; this script is for assertions.
swiftc -o "$DIR/cub-accounts-tests" \
    UsageLogic.swift UsageManager.swift Accounts.swift MenuBarIcon.swift \
    tests/support.swift tests/accounts/main.swift \
    -framework SwiftUI -framework AppKit \
    -suppress-warnings
"$DIR/cub-accounts-tests"

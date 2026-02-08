#!/bin/sh
set -e

# Gracefully quit existing instance so it can run cleanup (e.g. expanding windows)
pkill -INT -x Tabbed 2>/dev/null && sleep 1 || true

"$(dirname "$0")/build.sh"
open build/Build/Products/Debug/Tabbed.app

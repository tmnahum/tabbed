#!/bin/sh
set -e
xcodegen generate
xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build
open build/Build/Products/Debug/Tabbed.app

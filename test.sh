#!/bin/sh
set -e

# Load developer-specific settings
if [ -f .env ]; then
  export $(grep -v '^\s*#' .env | grep -v '^\s*$' | xargs)
fi

if [ -z "$DEVELOPMENT_TEAM" ]; then
  echo "Error: DEVELOPMENT_TEAM is not set."
  echo "Copy .env.example to .env and set your Team ID."
  echo "Find your Team ID with: security find-identity -v -p codesigning"
  exit 1
fi

xcodegen generate
xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  test

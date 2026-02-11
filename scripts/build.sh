#!/bin/sh
set -e

# Load developer-specific settings
if [ -f .env ]; then
  export $(grep -v '^\s*#' .env | grep -v '^\s*$' | xargs)
fi

XCODEBUILD_SIGNING_ARGS=""
if [ -z "$DEVELOPMENT_TEAM" ]; then
  echo "Warning: DEVELOPMENT_TEAM is not set. Building without code signing."
  XCODEBUILD_SIGNING_ARGS="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
else
  XCODEBUILD_SIGNING_ARGS="DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM -allowProvisioningUpdates"
fi

OUTPUT=$(xcodegen generate 2>&1 && \
  xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build \
    $XCODEBUILD_SIGNING_ARGS \
    build 2>&1) || {
  echo "$OUTPUT"
  exit 1
}

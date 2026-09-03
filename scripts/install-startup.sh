#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
BUILD_APP="$PROJECT_DIR/build/Build/Products/Debug/Tabbed.app"

cd "$PROJECT_DIR"
"$SCRIPT_DIR/build.sh"

STARTUP_URL=$(
  sfltool dumpbtm 2>/dev/null | awk '
    /Identifier: 2\.com\.tabbed\.Tabbed$/ { found = 1; next }
    found && /URL: file:\/\// {
      sub(/^.*URL: file:\/\//, "")
      sub(/\/$/, "")
      print
      exit
    }
  '
)

if [ -z "$STARTUP_URL" ]; then
  echo "Error: no Tabbed startup entry was found. Enable Start at Login in Tabbed Settings first." >&2
  exit 1
fi

case "$STARTUP_URL" in
  *%*)
    echo "Error: the registered startup path contains URL escapes and cannot be installed safely: $STARTUP_URL" >&2
    exit 1
    ;;
  */Tabbed.app) ;;
  *)
    echo "Error: refusing to replace unexpected startup target: $STARTUP_URL" >&2
    exit 1
    ;;
esac

RUNNING_PIDS=$(pgrep -f '/Tabbed\.app/Contents/MacOS/Tabbed$' || true)
if [ -n "$RUNNING_PIDS" ]; then
  for running_pid in $RUNNING_PIDS; do
    kill -INT "$running_pid"
  done

  attempts=0
  while pgrep -f '/Tabbed\.app/Contents/MacOS/Tabbed$' >/dev/null 2>&1 && [ "$attempts" -lt 25 ]; do
    sleep 0.2
    attempts=$((attempts + 1))
  done
fi

if [ "$BUILD_APP" != "$STARTUP_URL" ]; then
  STARTUP_PARENT=$(dirname -- "$STARTUP_URL")
  STAGING_DIR=$(mktemp -d "$STARTUP_PARENT/.tabbed-install.XXXXXX")
  STAGED_APP="$STAGING_DIR/Tabbed.app"
  BACKUP_APP="$STAGING_DIR/Previous-Tabbed.app"
  trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM

  ditto "$BUILD_APP" "$STAGED_APP"
  codesign --verify --deep --strict "$STAGED_APP"

  mv "$STARTUP_URL" "$BACKUP_APP"
  mv "$STAGED_APP" "$STARTUP_URL"
  if ! codesign --verify --deep --strict "$STARTUP_URL"; then
    mv "$STARTUP_URL" "$STAGED_APP"
    mv "$BACKUP_APP" "$STARTUP_URL"
    echo "Error: installed app failed signature verification; restored the previous bundle." >&2
    exit 1
  fi
else
  codesign --verify --deep --strict "$STARTUP_URL"
fi

open "$STARTUP_URL"

echo "Installed and launched the registered startup app: $STARTUP_URL"

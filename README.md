# Tabbed

A macOS menu bar utility that groups arbitrary windows into tab groups with a browser-style tab bar.

## Requirements

- macOS 13.0+
- Xcode Command Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup

Install XcodeGen if you don't have it:

```
brew install xcodegen
```

Generate the Xcode project and build:

```
xcodegen generate
xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build
```

Run:

```
open build/Build/Products/Debug/Tabbed.app
```

The app requires Accessibility permission. Grant it in System Settings > Privacy & Security > Accessibility when prompted.

## Development

The Xcode project is generated from `project.yml` — don't edit `Tabbed.xcodeproj` directly. After changing `project.yml` or adding/removing source files, regenerate:

```
xcodegen generate
```

Run tests:

```
xcodegen generate
xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test
```

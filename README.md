# Tabbed
![](./app-screenshot.jpeg)

## What is Tabbed?

Tabbed is a macos utility which lets you make your application windows tabs in a browser-inspired tab group metawindow. 

### How it works:
- windows in a group are synced to be in the same spot behind each other, and the tab bar is rendered on top. does not take over your system much beyond that

## Features:
- Supports maximization and window snapping, works in tandem with other window managers (tested with macos snapping + raycast)
- AltTab inspired quick switching functionality, which switches between and within window groups (by default replacing the macos model of switching between / within individual apps)
- quick app launcher with hyper+t (default) shortcut
- name your window groups and rename your tabs
- true fullscreen app handling is still being worked on...
- open source so you can just vibe code whatever changes you want... feel free to PR

## Installation
Tabbed is still in alpha / being worked on, so you will have to build it yourself. \
To build make sure you have the following installed:
- `xcodegen` (install with `brew install xcodegen`)
- macOS 13.0+ (tested on macos 15 on m1 air)
- Xcode 15+ (includes Swift 5.9 toolchain and macOS SDK)
    - Xcode Command Line Tools (`xcode-select --install`, if not already installed)
- Recommended: Apple Development code-signing identity
    - sign in with your apple id to xcode
    - rename .env.example to .env and fill in your own xcode development team id
- then build and run with `./scripts/buildandrun.sh`   

Will work on distributing a download coming soon



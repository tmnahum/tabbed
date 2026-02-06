# Contributing to Tabbed

## Prerequisites

- **macOS 13.0+**
- **Xcode** (includes `xcodebuild` and the Swift toolchain) — install from the Mac App Store
- **XcodeGen** — generates the Xcode project from `project.yml`
  ```sh
  brew install xcodegen
  ```

## Build and Run

First-time setup — copy and configure your `.env` file (see [development.md](development.md) for details):

```sh
cp .env.example .env
# Edit .env with your Team ID (find it with: security find-identity -v -p codesigning)
```

Then build and run:

```sh
./buildandrun.sh
```

Grant Accessibility permissions when prompted (System Settings > Privacy & Security > Accessibility). With code signing configured, this only needs to be done once.

## Running Tests

```sh
./run.sh
```

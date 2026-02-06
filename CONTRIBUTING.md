# Contributing to Tabbed

## Prerequisites

- **macOS 13.0+**
- **Xcode** (includes `xcodebuild` and the Swift toolchain) — install from the Mac App Store
- **XcodeGen** — generates the Xcode project from `project.yml`
  ```sh
  brew install xcodegen
  ```

## Setup

1. Clone the repository:
   ```sh
   git clone <repo-url>
   cd tabbed/version-a
   ```

2. Set your Apple Development team ID. You can find it by running:
   ```sh
   security find-identity -v -p codesigning
   ```
   Look for the ID in parentheses, e.g. `"Apple Development: you@example.com (XXXXXXXXXX)"` — the `XXXXXXXXXX` is your team ID.

   Export it in your shell (or add to your shell profile):
   ```sh
   export DEVELOPMENT_TEAM="your-team-id-here"
   ```

   This is needed so that macOS preserves Accessibility permissions across rebuilds. Without it, you'd have to re-grant permissions every time you build.

3. Build and run:
   ```sh
   ./buildandrun.sh
   ```

4. Grant Accessibility permissions when prompted (System Settings > Privacy & Security > Accessibility). You only need to do this once as long as your team ID is set.

## Running Tests

```sh
./run.sh
```

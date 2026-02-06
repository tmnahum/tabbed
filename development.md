# Development Setup

## Code Signing

The app uses "Apple Development" code signing so that macOS accessibility permissions persist across rebuilds. Without this, macOS treats every rebuild as a new app and revokes the accessibility grant.

### First-Time Setup

1. **Sign into Xcode with your Apple ID** (Xcode > Settings > Accounts) — a free account works.

2. **Find your Team ID:**
   ```sh
   security find-identity -v -p codesigning
   ```
   Look for the `OU=` field, or the 10-character alphanumeric ID associated with your "Apple Development" certificate.

3. **Create your `.env` file:**
   ```sh
   cp .env.example .env
   ```
   Edit `.env` and replace `YOUR_TEAM_ID` with your actual Team ID.

4. **Build and run:**
   ```sh
   ./buildandrun.sh
   ```

5. **Grant accessibility permission once** in System Settings > Privacy & Security > Accessibility. It will persist across rebuilds.

### How It Works

- `project.yml` sets `CODE_SIGN_IDENTITY: "Apple Development"` and `CODE_SIGN_STYLE: Automatic`
- `buildandrun.sh` reads `DEVELOPMENT_TEAM` from `.env` and passes it to `xcodebuild`
- `.env` is gitignored — each developer uses their own Team ID
- The stable signing identity means macOS TCC recognizes the rebuilt app as the same app

### Troubleshooting

**No signing identity found:** Make sure you've signed into Xcode with your Apple ID and that an "Apple Development" certificate appears in `security find-identity -v -p codesigning`.

**Accessibility permission not sticking:** Run `tccutil reset Accessibility com.tabbed.Tabbed` to clear stale TCC entries, then rebuild and re-grant.

**Building without an Apple account:** You can create a self-signed code signing certificate in Keychain Access (Certificate Assistant > Create a Certificate > Code Signing) and set `CODE_SIGN_IDENTITY` to its name. This is less reliable for TCC persistence on newer macOS versions.

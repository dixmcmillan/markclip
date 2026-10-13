# Privacy Policy

**Last updated:** March 22, 2026

## Overview

macshot is a free, open-source screenshot and screen recording tool for macOS. It is designed to run entirely on your device. We do not operate any servers, and we do not collect, store, or have access to any of your data.

## What macshot does NOT do

- **No telemetry or analytics** — macshot does not phone home, track usage, or send any data to us.
- **No data collection** — we do not collect personal information, usage statistics, crash reports, or any other data.
- **No server-side storage** — we do not operate any servers. All screenshots, recordings, and settings are stored locally on your Mac.
- **No access to your files** — we cannot see, access, or download your screenshots or recordings. Upload integrations (Google Drive, S3-compatible storage, imgbb) have been removed; Cloudflare Stream/Images upload from the video exporter is planned; this policy will be updated when it ships.

## Data stored on your device

macshot stores the following data locally on your Mac:

- **Screenshots and recordings** — saved to your chosen folder (default: Pictures).
- **Screenshot history** — recent captures stored in `~/Library/Application Support/com.sw33tlie.macshot/history/`. You control the history size in Preferences (set to 0 to disable).
- **Preferences** — settings stored in macOS UserDefaults.

## Third-party services

macshot integrates with the following third-party services:

### Sparkle (auto-updates)
- **Purpose:** Check for and install macshot updates.
- **Data sent:** A request to `https://raw.githubusercontent.com/sw33tLie/macshot/main/appcast.xml` to check for new versions. No personal data is included in the request.

## Permissions

macshot requests **Screen Recording** permission from macOS. This permission is required to capture screenshots and record your screen. macOS controls this permission — you can revoke it at any time in System Settings > Privacy & Security > Screen Recording.

## Open source

macshot is fully open source. You can inspect the complete source code at [https://github.com/sw33tLie/macshot](https://github.com/sw33tLie/macshot) to verify these claims.

## Contact

If you have questions about this privacy policy, open an issue at [https://github.com/sw33tLie/macshot/issues](https://github.com/sw33tLie/macshot/issues).

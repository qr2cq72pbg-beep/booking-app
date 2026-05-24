# Booking — Capacitor mobile wrapper

Native iOS/Android shell around the existing web app. **No changes** to `index.html` or booking logic — the wrapper loads the deployed Vercel app by default.

| Setting | Value |
|--------|--------|
| App name | Booking |
| App ID | `com.gtwebstudio.booking` |
| Default URL | `https://booking-app-fawn-five.vercel.app` |

## Prerequisites

- **Node.js** 18+ and npm
- **iOS:** macOS, Xcode 15+, CocoaPods (`sudo gem install cocoapods`)
- **Android:** Android Studio, JDK 17+, Android SDK

## One-time setup

```bash
cd "/Users/gorgeterziev/booking appp"
npm install
npm run web:copy
npx cap add ios
npx cap add android
npm run cap:sync
```

## Commands

| Command | Purpose |
|---------|---------|
| `npm run web:copy` | Copy `index.html`, `manifest.json`, `icons/` → `www/` (read-only copy) |
| `npm run cap:sync` | Copy web assets + sync native projects |
| `npm run cap:open:ios` | Open Xcode workspace |
| `npm run cap:open:android` | Open Android Studio |
| `npm run cap:run:ios` | Sync and run on iOS simulator/device |
| `npm run cap:run:android` | Sync and run on Android emulator/device |

### Load modes

**Remote (default)** — WebView opens production Vercel:

```bash
npm run cap:sync
```

**Another URL** (staging / local static server):

```bash
CAPACITOR_SERVER_URL=http://127.0.0.1:8080 npm run cap:sync
```

**Bundled** — ship copied files from `www/` (no live URL; for future store offline builds):

```bash
CAPACITOR_USE_REMOTE=false npm run cap:sync
```

## Run locally

### iOS

```bash
npm run cap:run:ios
# or
npm run cap:sync && npx cap open ios
# In Xcode: select simulator → Run (⌘R)
```

### Android

```bash
npm run cap:run:android
# or
npm run cap:sync && npx cap open android
# In Android Studio: Run on emulator/device
```

## Files added (Capacitor phase)

| Path | Role |
|------|------|
| `package.json` | Capacitor deps + npm scripts |
| `capacitor.config.ts` | App id, name, `webDir`, remote `server.url` |
| `scripts/copy-web-assets.mjs` | Copies static web into `www/` without editing sources |
| `www/` | Generated Capacitor web root (gitignored except `.gitkeep`) |
| `ios/` | Xcode project (after `npx cap add ios`) |
| `android/` | Gradle project (after `npx cap add android`) |
| `CAPACITOR.md` | This guide |
| `.gitignore` | `node_modules`, generated `www/` |

## Local notifications (Phase 1)

Native **local** reminders only — no SMS, no remote APNs/FCM yet. Email (Resend) unchanged.

| Plugin | `@capacitor/local-notifications` |
|--------|----------------------------------|
| Customer | 24h + 2h reminders after in-app booking (if permission granted) |
| Admin | “New booking received” when a booking arrives while admin view is open |
| Alerts tab | Permission status, enable, test notification, upcoming reminders list |

After pulling changes:

```bash
npm install
npm run cap:sync
```

**iOS:** Allow notifications when prompted (Alerts tab or after first booking tip).  
**Android 13+:** `POST_NOTIFICATIONS` permission is declared in the manifest.

Debug console tags: `[notifications]`, `[notification-permission]`, `[notification-scheduled]`, `[notification-skipped]`, `[notification-click]`.

## Not in this phase

- Remote push (APNs / FCM server)
- SMS notifications
- App Store / Play Store submission
- UI refactor of the web app
- Custom native plugins

## Apple / Google — still required later

- **Apple Developer Program** ($99/yr), App ID matching `com.gtwebstudio.booking`, provisioning profiles, signing in Xcode
- **Google Play Console** ($25 one-time), signing keystore, app listing, privacy policy URL
- **Icons & splash** — native asset sets in `ios/App/App/Assets.xcassets` and `android/app/src/main/res`
- **Privacy / ATS** — App Store review; ensure Supabase/third-party domains allowed in iOS App Transport Security if bundling locally
- **Deep links** — optional `?business=` universal links / app links
- **Push** — APNs + FCM when you add `@capacitor/push-notifications`

## Risks & notes

1. **Remote URL mode** — App requires network; behaves like a WebView to Vercel. Good for phase 1; store review may ask for offline behavior or bundled assets later (`CAPACITOR_USE_REMOTE=false`).
2. **Cookies / auth** — Supabase session cookies live in the WebView; test login/logout on real devices.
3. **Safe area / PWA** — Existing mobile shell CSS applies inside WebView; verify status bar overlap on notched iPhones.
4. **Third-party cookies** — iOS ITP may affect some flows; test customer login and booking end-to-end.
5. **Updates** — Web changes deploy to Vercel instantly in remote mode; native wrapper updates only when you change Capacitor config or ship a new store build.
6. **Regenerating native projects** — Deleting `ios/` / `android/` and re-running `npx cap add` is safe; custom native edits would be lost.
7. **CocoaPods** — First iOS build runs `pod install` in `ios/App`; can take several minutes.

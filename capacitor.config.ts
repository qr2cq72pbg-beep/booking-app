import type { CapacitorConfig } from "@capacitor/cli";

/**
 * Production web app (Vercel). Override for local dev:
 *   CAPACITOR_SERVER_URL=http://localhost:3000 npm run cap:sync
 *
 * Bundle copied assets instead of remote URL (offline / store builds later):
 *   CAPACITOR_USE_REMOTE=false npm run cap:sync
 */
const PRODUCTION_APP_URL = "https://booking-app-fawn-five.vercel.app";
// Local device testing: force bundled www/ instead of remote server.url.
const useRemote = false;
const remoteUrl = (process.env.CAPACITOR_SERVER_URL || PRODUCTION_APP_URL).trim();

const config: CapacitorConfig = {
  appId: "com.gtwebstudio.booking",
  appName: "Booking",
  webDir: "www",
  ...(useRemote && remoteUrl
    ? {
        server: {
          url: remoteUrl,
          cleartext: false,
          androidScheme: "https"
        }
      }
    : {}),
  ios: {
    contentInset: "never",
    backgroundColor: "#e7eef8"
  },
  android: {
    allowMixedContent: false
  },
  plugins: {
    PushNotifications: {
      presentationOptions: ["alert", "sound", "badge"],
      // Custom XBook flag (not read by the Capacitor plugin).
      // Keep false until android/app/google-services.json is present and the
      // native Android app is rebuilt. register() without FirebaseApp crashes.
      androidRegister: true
    }
  }
};

export default config;

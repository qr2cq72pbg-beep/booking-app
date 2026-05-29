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
    backgroundColor: "#f8f9fe"
  },
  android: {
    allowMixedContent: false
  }
};

export default config;

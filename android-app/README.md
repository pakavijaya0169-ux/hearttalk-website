# HeartTalk Android wrapper

This Android Studio project wraps the published HeartTalk website in a WebView.

## Build
1. Install Android Studio (with Android SDK 35).
2. Open the `android-app` folder in Android Studio (not the repository root).
3. Allow Gradle sync and install any requested Android SDK components.
4. Connect an Android phone with USB debugging enabled, or create an emulator.
5. Press Run to install the app.

## Screenshot / recording protection
`MainActivity` polls the visible HeartTalk UI and applies Android `WindowManager.LayoutParams.FLAG_SECURE` only while `chatView`, `activeAudioCall`, or `activeVideoCall` is visible. Android then blocks OS screenshots and screen recording for those protected screens. This does not prevent filming the display with another device.

Camera and microphone permissions are requested by the WebView when a call needs them. This wrapper is a starter build and must be tested on real Android devices before public release.


Build refresh: 2026-11-11 — rebuild APK with latest website JavaScript fix.

Chat screen layout refresh: 2026-11-11.

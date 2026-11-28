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

APK refresh: include profile session and null-element fixes.


Store UI build refresh: 2026-11-11. Android WebView loads the latest HeartTalk GitHub Pages website, including the Gifts, Frames and Wallpapers Store screen.


Coin packages wallet UI updated; rebuild Android wrapper against the latest HeartTalk website.


Trigger APK rebuild for updated HeartTalk coin package list.


Rebuild Android APK after updating HeartTalk coin package pricing.


Trigger Android APK build for latest starter coin package updates.


Store catalogue refresh: 2026-11-13 — rebuild the Android WebView APK with the latest Gifts, Profile Frames and Wallpapers Store UI. Frames and wallpapers are preview-only; no purchase/apply flow is enabled.


Store blank-grid fix: 2026-11-13 — rebuild Android APK with static fallback gift cards and auth-state refresh.


## Ongoing call support (2026-11-28)
- The Android wrapper starts a native foreground service while a HeartTalk voice/video call is active. An ongoing notification lets users return after switching apps.
- Video calls enable Android Picture-in-Picture when users leave HeartTalk, where supported.
- Android 14+ requires microphone/camera permission grants before calls start; the service is started while HeartTalk is visible.
- Validate voice background continuity and video PiP on physical Android devices (Android 13, 14, and 15+) before public release. A successful Gradle build alone does not prove device-level call continuity.

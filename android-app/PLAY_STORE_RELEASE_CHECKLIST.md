# HeartTalk Google Play release checklist

## Build preparation completed in this branch
- Android compile SDK and target SDK are set to API 36.
- Android Gradle Plugin and Gradle wrapper runtime are aligned for the API 36 build.
- GitHub Actions builds a debug APK for device testing and a release AAB for the next signing step.

## Still required before Play Console upload
1. **Release signing:** create and securely back up an upload keystore. Configure the release signing credentials as GitHub Actions secrets or sign the AAB locally. Never commit keystore files or passwords.
2. **Firebase:** confirm the production `google-services.json` belongs to the production Firebase project and that FCM token registration is implemented and tested. Do not publish a package with a missing or development Firebase configuration.
3. **Policy pages:** replace all draft wording in `legal.html` with the real operator name, contact email/address, data retention, deletion process, grievance/support contact, third-party processors, international transfers, refund terms, and applicable governing terms. Obtain legal review.
4. **Account deletion:** implement in-app account deletion and a public web deletion-request page. Deletion must cover the account and associated personal data, subject to clearly explained lawful retention exceptions.
5. **UGC safety:** verify that users can report content/accounts and block users; provide active moderation, published community standards, and a process to handle reports.
6. **Google Play declarations:** complete Data safety, content rating, target audience, ads, app access instructions, privacy policy URL, and any permissions declarations accurately.
7. **Payments:** do not enable real-money coin purchases, paid calls, or host cash-outs until a payment provider has explicitly approved the complete business model and the app's payment policy has been reviewed for Google Play compliance. The current Razorpay account was not approved; do not route payments through it.
8. **Testing:** install the release-signed build on multiple Android versions/devices. Test signup/login, logout, password reset, profile, chat text/media, camera/microphone permissions, calls, notifications, report/block, account deletion, offline/network recovery, and crash handling. Verify privacy/data handling and all store listing links.
9. **Store assets:** prepare app icon, feature graphic, phone screenshots, short/full descriptions, support contact, and a public website.
10. **Versioning:** increment `versionCode` for every subsequent Play upload.

## Important
The AAB produced by the current workflow is an **unsigned release bundle** until release signing is configured. It is not ready to upload to Google Play. A successful CI build only confirms compilation; it does not certify app behavior, policy compliance, or Play approval.

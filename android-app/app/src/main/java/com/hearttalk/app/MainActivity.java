package com.hearttalk.app;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Build;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView webView;
    private PermissionRequest pendingPermissionRequest;
    private static final int MEDIA_PERMISSION_REQUEST = 71;
    private static final int NOTIFICATION_PERMISSION_REQUEST = 72;
    private final String appUrl = "https://pakavijaya0169-ux.github.io/hearttalk-website/";

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        webView = new WebView(this);
        setContentView(webView);
        requestNotificationPermissionIfNeeded();

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(true);
        settings.setSupportMultipleWindows(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);

        webView.setWebViewClient(new WebViewClient());
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> {
                    String origin = request.getOrigin() == null ? "" : request.getOrigin().toString();
                    // Only grant media capture to the exact HeartTalk website origin.
                    if (!"https://pakavijaya0169-ux.github.io".equals(origin)) {
                        request.deny();
                        return;
                    }

                    boolean needsAudio = false;
                    boolean needsCamera = false;
                    for (String resource : request.getResources()) {
                        if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)) needsAudio = true;
                        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)) needsCamera = true;
                    }
                    if (!needsAudio && !needsCamera) {
                        request.deny();
                        return;
                    }

                    pendingPermissionRequest = request;
                    boolean audioGranted = !needsAudio || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
                    boolean cameraGranted = !needsCamera || checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
                    if (audioGranted && cameraGranted) {
                        request.grant(request.getResources());
                        pendingPermissionRequest = null;
                    } else {
                        java.util.ArrayList<String> permissions = new java.util.ArrayList<>();
                        if (needsAudio && !audioGranted) permissions.add(Manifest.permission.RECORD_AUDIO);
                        if (needsCamera && !cameraGranted) permissions.add(Manifest.permission.CAMERA);
                        requestPermissions(permissions.toArray(new String[0]), MEDIA_PERMISSION_REQUEST);
                    }
                });
            }

            @Override public void onPermissionRequestCanceled(PermissionRequest request) {
                if (pendingPermissionRequest == request) pendingPermissionRequest = null;
            }
        });
        webView.loadUrl(appUrl);
        webView.postDelayed(securityCheck, 500);
    }

    private final Runnable securityCheck = new Runnable() {
        @Override public void run() {
            if (webView == null) return;
            String js = "(function(){const visible=id=>{const e=document.getElementById(id);if(!e)return false;const s=getComputedStyle(e);return s.display!=='none'&&s.visibility!=='hidden'&&e.getBoundingClientRect().width>0&&e.getBoundingClientRect().height>0};return !!(visible('chatView')&&document.getElementById('chatView').classList.contains('active') || visible('activeAudioCall') || visible('activeVideoCall'));})()";
            webView.evaluateJavascript(js, value -> {
                boolean protect = "true".equals(value);
                if (protect) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
                else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
            });
            webView.postDelayed(this, 500);
        }
    };

    private void requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION_REQUEST);
        }
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == MEDIA_PERMISSION_REQUEST && pendingPermissionRequest != null) {
            boolean granted = grantResults.length > 0;
            for (int result : grantResults) granted &= result == PackageManager.PERMISSION_GRANTED;
            if (granted) pendingPermissionRequest.grant(pendingPermissionRequest.getResources());
            else pendingPermissionRequest.deny();
            pendingPermissionRequest = null;
        }
    }

    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }

    @Override protected void onDestroy() {
        if (webView != null) { webView.removeCallbacks(securityCheck); webView.destroy(); webView = null; }
        super.onDestroy();
    }
}
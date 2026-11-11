package com.hearttalk.app;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.ActivityNotFoundException;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Build;
import android.net.Uri;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.ValueCallback;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView webView;
    private PermissionRequest pendingPermissionRequest;
    private ValueCallback<Uri[]> fileChooserCallback;
    private static final int FILE_CHOOSER_REQUEST = 73;
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
                runOnUiThread(() -> handleWebMediaPermission(request));
            }

            @Override public boolean onShowFileChooser(
                    WebView view,
                    ValueCallback<Uri[]> filePathCallback,
                    FileChooserParams fileChooserParams) {
                if (fileChooserCallback != null) {
                    fileChooserCallback.onReceiveValue(null);
                    fileChooserCallback = null;
                }
                fileChooserCallback = filePathCallback;
                try {
                    Intent chooserIntent = fileChooserParams.createIntent();
                    startActivityForResult(chooserIntent, FILE_CHOOSER_REQUEST);
                    return true;
                } catch (ActivityNotFoundException e) {
                    fileChooserCallback = null;
                    filePathCallback.onReceiveValue(null);
                    return false;
                }
            }

            @Override public void onPermissionRequestCanceled(PermissionRequest request) {
                if (pendingPermissionRequest == request) pendingPermissionRequest = null;
            }
        });
        webView.loadUrl(appUrl);
        webView.postDelayed(securityCheck, 500);
    }

    private void handleWebMediaPermission(PermissionRequest request) {
        Uri origin = request.getOrigin();
        if (origin == null
                || !"https".equalsIgnoreCase(origin.getScheme())
                || !"pakavijaya0169-ux.github.io".equalsIgnoreCase(origin.getHost())) {
            request.deny();
            return;
        }

        java.util.ArrayList<String> requestedResources = new java.util.ArrayList<>();
        boolean needsAudio = false;
        boolean needsCamera = false;
        for (String resource : request.getResources()) {
            if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)) {
                needsAudio = true;
                requestedResources.add(resource);
            } else if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)) {
                needsCamera = true;
                requestedResources.add(resource);
            }
        }
        if (requestedResources.isEmpty()) {
            request.deny();
            return;
        }

        boolean audioGranted = !needsAudio
                || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
        boolean cameraGranted = !needsCamera
                || checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
        if (audioGranted && cameraGranted) {
            request.grant(requestedResources.toArray(new String[0]));
            return;
        }

        pendingPermissionRequest = request;
        java.util.ArrayList<String> permissions = new java.util.ArrayList<>();
        if (needsAudio && !audioGranted) permissions.add(Manifest.permission.RECORD_AUDIO);
        if (needsCamera && !cameraGranted) permissions.add(Manifest.permission.CAMERA);
        requestPermissions(permissions.toArray(new String[0]), MEDIA_PERMISSION_REQUEST);
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
            if (granted) {
                java.util.ArrayList<String> allowedResources = new java.util.ArrayList<>();
                for (String resource : pendingPermissionRequest.getResources()) {
                    if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)
                            && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        allowedResources.add(resource);
                    }
                    if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)
                            && checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        allowedResources.add(resource);
                    }
                }
                if (!allowedResources.isEmpty()) pendingPermissionRequest.grant(allowedResources.toArray(new String[0]));
                else pendingPermissionRequest.deny();
            } else pendingPermissionRequest.deny();
            pendingPermissionRequest = null;
        }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_CHOOSER_REQUEST) {
            if (fileChooserCallback != null) {
                Uri[] results = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
                fileChooserCallback.onReceiveValue(results);
                fileChooserCallback = null;
            }
        }
    }

    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }

    @Override protected void onDestroy() {
        if (fileChooserCallback != null) { fileChooserCallback.onReceiveValue(null); fileChooserCallback = null; }
        if (webView != null) { webView.removeCallbacks(securityCheck); webView.destroy(); webView = null; }
        super.onDestroy();
    }
}
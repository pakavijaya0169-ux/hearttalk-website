package com.hearttalk.app;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.ConsoleMessage;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.graphics.Color;

public class MainActivity extends Activity {
    private WebView webView;
    private TextView diagnostic;
    private PermissionRequest pendingPermissionRequest;
    private static final int MEDIA_PERMISSION_REQUEST = 71;
    private final String appUrl = "https://pakavijaya0169-ux.github.io/hearttalk-website/";

    private void report(String message) {
        runOnUiThread(() -> {
            if (diagnostic == null) return;
            diagnostic.setText((diagnostic.getText() + "\n" + message));
            diagnostic.setVisibility(View.VISIBLE);
        });
    }

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        FrameLayout root = new FrameLayout(this);
        webView = new WebView(this);
        diagnostic = new TextView(this);
        diagnostic.setTextColor(Color.WHITE);
        diagnostic.setBackgroundColor(0xDD8B174F);
        diagnostic.setTextSize(11);
        diagnostic.setPadding(12, 8, 12, 8);
        diagnostic.setText("HeartTalk diagnostics: loading…");
        diagnostic.setMaxLines(7);
        diagnostic.setOnClickListener(v -> { diagnostic.setVisibility(View.GONE); diagnostic.setText("HeartTalk diagnostics:"); });
        root.addView(webView, new FrameLayout.LayoutParams(-1, -1));
        FrameLayout.LayoutParams debugParams = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        root.addView(diagnostic, debugParams);
        setContentView(root);

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);
        WebView.setWebContentsDebuggingEnabled(true);

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

        webView.setWebViewClient(new WebViewClient() {
            @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                report("Loading: " + url);
            }
            @Override public void onPageFinished(WebView view, String url) {
                report("Page loaded. Checking JavaScript…");
                view.evaluateJavascript("(function(){return 'JS active; Supabase='+(typeof window.supabase)+'; client='+(typeof window.supabaseClient)+'; buttons='+document.querySelectorAll('button').length})()", value -> report(value));
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) report("PAGE ERROR: " + error.getDescription());
            }
            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame() || response.getStatusCode() >= 400) report("HTTP " + response.getStatusCode() + ": " + request.getUrl());
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onConsoleMessage(ConsoleMessage message) {
                if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR ||
                    message.messageLevel() == ConsoleMessage.MessageLevel.WARNING) {
                    report(message.messageLevel() + ": " + message.message() + " (line " + message.lineNumber() + ")");
                }
                return true;
            }
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> {
                    pendingPermissionRequest = request;
                    if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
                        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        request.grant(request.getResources());
                    } else {
                        requestPermissions(new String[]{Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO}, MEDIA_PERMISSION_REQUEST);
                    }
                });
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
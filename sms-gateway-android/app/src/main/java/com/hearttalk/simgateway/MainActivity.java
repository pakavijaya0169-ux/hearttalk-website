package com.hearttalk.simgateway;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.telephony.SmsManager;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import android.text.InputType;
import org.json.JSONObject;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class MainActivity extends Activity {
  private EditText endpoint, token;
  private TextView status;
  private Button startButton;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
  private final AtomicBoolean running = new AtomicBoolean(false);
  private static final int SMS_PERMISSION = 42;

  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    LinearLayout root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setPadding(28, 36, 28, 28);
    root.setGravity(Gravity.CENTER_HORIZONTAL);
    TextView title = new TextView(this);
    title.setText("HeartTalk SIM Gateway");
    title.setTextSize(24);
    root.addView(title);
    TextView info = new TextView(this);
    info.setText("Install only on your dedicated gateway phone with its SIM. Keep this screen open while receiving OTP jobs.");
    info.setPadding(0, 16, 0, 18);
    root.addView(info);
    endpoint = new EditText(this);
    endpoint.setSingleLine(true);
    endpoint.setHint("Supabase Function URL");
    endpoint.setText(getPreferences(0).getString("endpoint", ""));
    root.addView(endpoint);
    token = new EditText(this);
    token.setSingleLine(true);
    token.setHint("Gateway token");
    token.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    token.setText(getPreferences(0).getString("token", ""));
    root.addView(token);
    startButton = new Button(this);
    startButton.setText("Start gateway");
    root.addView(startButton);
    status = new TextView(this);
    status.setText("Stopped");
    status.setPadding(0, 20, 0, 0);
    root.addView(status);
    setContentView(root);

    startButton.setOnClickListener(v -> {
      if (running.get()) { stopGateway(); return; }
      String u = endpoint.getText().toString().trim();
      String t = token.getText().toString().trim();
      if (!u.startsWith("https://") || t.length() < 32) {
        status.setText("Enter HTTPS function URL and a strong gateway token.");
        return;
      }
      getPreferences(0).edit().putString("endpoint", u).putString("token", t).apply();
      if (checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
        requestPermissions(new String[]{Manifest.permission.SEND_SMS}, SMS_PERMISSION);
      } else startGateway();
    });
  }

  private void startGateway() {
    if (!running.compareAndSet(false, true)) return;
    endpoint.setEnabled(false); token.setEnabled(false);
    startButton.setText("Stop gateway");
    status.setText("Running — checking for OTP messages…");
    scheduler.scheduleWithFixedDelay(() -> executor.execute(this::pollOnce), 0, 5, TimeUnit.SECONDS);
  }

  private void stopGateway() {
    running.set(false);
    scheduler.shutdownNow();
    endpoint.setEnabled(true); token.setEnabled(true);
    startButton.setText("Start gateway");
    status.setText("Stopped. Reopen the app to start again.");
  }

  private void pollOnce() {
    if (!running.get()) return;
    HttpURLConnection c = null;
    try {
      JSONObject request = new JSONObject(); request.put("action", "poll");
      c = post(request);
      if (c.getResponseCode() != 200) throw new IOException("Gateway HTTP " + c.getResponseCode());
      String response = read(c.getInputStream());
      JSONObject data = new JSONObject(response);
      if (data.isNull("job")) return;
      JSONObject job = data.getJSONObject("job");
      long id = job.getLong("id");
      String phone = job.getString("phone");
      String message = job.getString("message");
      boolean sent = false; String error = "";
      try {
        SmsManager manager = getSystemService(SmsManager.class);
        if (manager == null) throw new Exception("SMS service unavailable");
        java.util.ArrayList<String> parts = manager.divideMessage(message);
        if (parts.size() == 1) manager.sendTextMessage(phone, null, message, null, null);
        else manager.sendMultipartTextMessage(phone, null, parts, null, null);
        sent = true;
      } catch (Exception e) { error = e.getMessage() == null ? "SMS send failed" : e.getMessage(); }
      JSONObject ack = new JSONObject();
      ack.put("action", "ack"); ack.put("id", id); ack.put("sent", sent); ack.put("error", error);
      HttpURLConnection ackConn = post(ack);
      int code = ackConn.getResponseCode(); ackConn.disconnect();
      final String result = sent && code == 200 ? "SMS submitted to SIM network for " + phone : "SMS failed: " + error;
      runOnUiThread(() -> status.setText(result));
    } catch (Exception e) {
      final String msg = "Gateway connection error: " + e.getMessage();
      runOnUiThread(() -> status.setText(msg));
    } finally { if (c != null) c.disconnect(); }
  }

  private HttpURLConnection post(JSONObject body) throws Exception {
    HttpURLConnection c = (HttpURLConnection) new URL(endpoint.getText().toString().trim()).openConnection();
    c.setRequestMethod("POST"); c.setConnectTimeout(10000); c.setReadTimeout(15000);
    c.setDoOutput(true); c.setRequestProperty("Content-Type", "application/json");
    c.setRequestProperty("Authorization", "Bearer " + token.getText().toString().trim());
    try (OutputStream out = c.getOutputStream()) {
      out.write(body.toString().getBytes(StandardCharsets.UTF_8));
    }
    return c;
  }

  private String read(InputStream in) throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] buffer = new byte[2048]; int n;
    while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
    return out.toString("UTF-8");
  }

  @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(requestCode, permissions, results);
    if (requestCode == SMS_PERMISSION && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) startGateway();
    else status.setText("SMS permission is required on this dedicated gateway phone.");
  }

  @Override protected void onDestroy() {
    running.set(false); scheduler.shutdownNow(); executor.shutdownNow(); super.onDestroy();
  }
}
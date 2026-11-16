const CACHE_NAME = "hearttalk-v10";
const FILES_TO_CACHE = [
  "/hearttalk-website/",
  "/hearttalk-website/manifest.json",
  "/hearttalk-website/icons/icon-192.svg",
  "/hearttalk-website/icons/icon.svg"
];

importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDV4iEnxAIAKejGhAKMvXDrqvPPr4LCKas",
  authDomain: "hearttalk0169.firebaseapp.com",
  projectId: "hearttalk0169",
  storageBucket: "hearttalk0169.firebasestorage.app",
  messagingSenderId: "125077497164",
  appId: "1:125077497164:web:ea097e0d317e5177acdbe9",
  measurementId: "G-3YCTN9HBE1"
});
const messaging = firebase.messaging();

messaging.onBackgroundMessage(payload => {
  const data = payload.data || {};
  const notification = payload.notification || {};
  const title = notification.title || data.title || "HeartTalk";
  const body = notification.body || data.body || "You have a new update.";
  const image = notification.image || data.image || data.image_url;
  const url = data.url || data.click_action || "/hearttalk-website/";
  return self.registration.showNotification(title, {
    body,
    icon: "/hearttalk-website/icons/icon-192.svg",
    badge: "/hearttalk-website/icons/icon-192.svg",
    ...(image ? { image } : {}),
    tag: data.tag || "hearttalk-push",
    data: { url }
  });
});

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(FILES_TO_CACHE)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)))
  ));
  self.clients.claim();
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL(
    event.notification.data?.url || "/hearttalk-website/",
    self.location.origin
  ).href;

  event.waitUntil((async () => {
    const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if (client.url.startsWith(self.location.origin) && "focus" in client) {
        await client.focus();
        if ("navigate" in client && client.url !== target) await client.navigate(target);
        return;
      }
    }
    await clients.openWindow(target);
  })());
});

self.addEventListener("fetch", event => {
  if (event.request.method === "GET") {
    event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
  }
});

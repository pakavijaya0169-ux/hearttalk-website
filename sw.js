const CACHE_NAME = "hearttalk-v9";
const FILES_TO_CACHE = [
  "/hearttalk-website/",
  "/hearttalk-website/manifest.json",
  "/hearttalk-website/icons/icon-192.svg",
  "/hearttalk-website/icons/icon.svg"
];

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

/*
 * FCM delivers background Web Push messages to this service worker.
 * The sender can use either a standard FCM notification payload or data payload.
 * Image URLs must be publicly reachable HTTPS URLs (for example, the
 * HeartTalk notification-images Supabase Storage bucket).
 */
self.addEventListener("push", event => {
  event.waitUntil((async () => {
    let payload = {};
    try {
      payload = event.data ? event.data.json() : {};
    } catch (_) {
      payload = { data: { body: event.data ? event.data.text() : "" } };
    }

    const data = payload.data || {};
    const notification = payload.notification || {};
    const title = notification.title || data.title || "HeartTalk";
    const body = notification.body || data.body || "You have a new update.";
    const image = notification.image || data.image || data.image_url || undefined;
    const url = data.url || data.click_action || "/hearttalk-website/";

    await self.registration.showNotification(title, {
      body,
      icon: "/hearttalk-website/icons/icon-192.svg",
      badge: "/hearttalk-website/icons/icon-192.svg",
      image,
      tag: data.tag || "hearttalk-push",
      renotify: Boolean(data.renotify === "true"),
      data: { url }
    });
  })());
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

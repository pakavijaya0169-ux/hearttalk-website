const CACHE_NAME = "hearttalk-v6";
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
self.addEventListener("fetch", event => {
  if (event.request.method === "GET") {
    event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
  }
});

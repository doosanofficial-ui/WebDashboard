const CACHE_NAME = "telemetry-dashboard-v8";
const STATIC_ASSETS = [
  "/", "/index.html", "/styles.css", "/app.js", "/naver-map.js", "/naver-roadview.js",
  "/ws.js", "/gps.js", "/ui.js", "/charts.js", "/manifest.json",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(STATIC_ASSETS))
      // A full/disabled cache must not prevent replacing a stale cache-first worker.
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys
      .filter((key) => key.startsWith("telemetry-dashboard-") && key !== CACHE_NAME)
      .map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin ||
      !STATIC_ASSETS.includes(url.pathname)) {
    return;
  }
  event.respondWith((async () => {
    try {
      const response = await fetch(event.request, { cache: "no-cache" });
      if (response.ok) {
        try {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(url.pathname, response.clone());
        } catch {
          // Online operation must survive cache quota/private-mode failures.
        }
      }
      return response;
    } catch (error) {
      const cache = await caches.open(CACHE_NAME);
      const cached = await cache.match(url.pathname);
      if (cached) return cached;
      if (event.request.mode === "navigate") {
        const shell = await cache.match("/index.html");
        if (shell) return shell;
      }
      throw error;
    }
  })());
});

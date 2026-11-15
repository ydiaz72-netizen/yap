// PonteTalk offline support: the game keeps working with weak or no signal.
const CACHE = "pontetalk-v4";
const CORE = ["/", "/index.html", "/manifest.webmanifest", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png", "/supabase.js",
  "/fonts/fredoka-latin-wght-normal.woff2", "/fonts/fredoka-latin-ext-wght-normal.woff2",
  "/fonts/nunito-latin-wght-normal.woff2", "/fonts/nunito-latin-ext-wght-normal.woff2",
  "/fonts/nunito-cyrillic-wght-normal.woff2", "/fonts/nunito-cyrillic-ext-wght-normal.woff2",
  "/fonts/noto-nastaliq-urdu-arabic-wght-normal.woff2"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  // Only this site's own files. Logins, saved games and online play always go straight to the internet.
  if (new URL(req.url).origin !== self.location.origin) return;
  // Pages: try the network first (so updates show up), fall back to the saved copy offline.
  if (req.mode === "navigate") {
    e.respondWith(fetch(req).then(res => { const copy = res.clone(); caches.open(CACHE).then(c => c.put("/index.html", copy)); return res; })
      .catch(() => caches.match("/index.html")));
    return;
  }
  // Everything else (icons, fonts, supabase.js): saved copy first, refresh in the background.
  e.respondWith(caches.match(req).then(hit => {
    const net = fetch(req).then(res => { if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return res; }).catch(() => hit);
    return hit || net;
  }));
});

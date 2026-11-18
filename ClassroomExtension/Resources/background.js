// Relays the scraped items from the content script to the native app. Content scripts can't
// call native messaging directly in Safari, so this background worker does it.

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.kind !== "classly-import") return false;
  (async () => {
    try {
      const reply = await browser.runtime.sendNativeMessage("com.visiocapital.classly", {
        items: message.items
      });
      sendResponse(reply && reply.ok ? { ok: true } : { ok: false, error: (reply && reply.error) || "App could not save." });
    } catch (e) {
      sendResponse({ ok: false, error: e.message || "Native messaging failed." });
    }
  })();
  return true;  // keep the channel open for the async response
});

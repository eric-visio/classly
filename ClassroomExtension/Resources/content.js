// Runs on classroom.google.com. It only does anything when Classly launched the page with
// the #classly-sync marker, so normal Classroom browsing is never touched.
//
// To get accurate turn-in status, it walks TWO of Classroom's own lists in sequence:
//   1. "not turned in"  -> Assigned + Missing (outstanding work)
//   2. "turned in"      -> Done (optionally "turned in late")
// Each scraped item is tagged with which list it came from, so the app can line up
// Upcoming / Off-track / Done with exactly what the student sees in Classroom. Items are
// accumulated in sessionStorage across the two page loads, then sent to the app at the end.

(function () {
  if (!/classly-sync/.test(location.hash + location.search)) return;

  const SYNC_SCHEME = "classly://classroom-imported";
  const PHASES = [
    { key: "not-turned-in", path: "/a/not-turned-in/all" },
    { key: "turned-in",     path: "/a/turned-in/all" }
  ];
  const K_ITEMS = "classly-items";
  const K_PHASE = "classly-phase";
  const K_START = "classly-start";
  const K_ACCT = "classly-acct";
  const MAX_ACCT = 6;
  const started = Date.now();

  // Which signed-in Google account holds the school's Classroom. The default (/u/0) is often a
  // personal account with no classes, so we discover the index that actually has assignments and
  // then stay on it for every list.
  let uSeg = sessionStorage.getItem(K_ACCT) || "";

  function currentUIndex() {
    const m = location.pathname.match(/^\/u\/(\d+)\//);
    return m ? parseInt(m[1], 10) : 0;
  }
  function gotoAccount(idx) {
    location.href = location.origin + "/u/" + idx + "/a/not-turned-in/all?classly-sync#classly-sync";
  }

  // Which list are we on? A fresh run — or a stale one older than 60s — restarts at phase 0.
  let phase = parseInt(sessionStorage.getItem(K_PHASE) || "", 10);
  const startedAt = parseInt(sessionStorage.getItem(K_START) || "0", 10);
  if (isNaN(phase) || !startedAt || Date.now() - startedAt > 60000) {
    phase = 0;
    sessionStorage.setItem(K_ITEMS, "[]");
    sessionStorage.setItem(K_START, String(Date.now()));
  }
  sessionStorage.setItem(K_PHASE, String(phase));

  const STATUS_WORD = /^(Missing|Turned in|Done|Graded|Returned|Assigned|Late)\b/i;

  function scrape(statusKey) {
    const items = new Map();
    for (const anchor of document.querySelectorAll('a[href*="/a/"]')) {
      let url;
      try { url = new URL(anchor.href); } catch { continue; }
      const m = url.pathname.match(/\/c\/([^/]+)\/a\/([^/]+)(?:\/details)?\/?$/);
      if (url.origin !== "https://classroom.google.com" || !m) continue;
      if (!anchor.getClientRects().length) continue;            // skip hidden
      const assignmentId = m[2];
      if (items.has(assignmentId)) continue;

      const title = (anchor.innerText || "").trim().split("\n")[0]
        || (anchor.getAttribute("aria-label") || "").trim();
      if (!title) continue;

      let courseName = "Classroom";
      let dueText = null;
      let statusLabel = null;
      for (let node = anchor, depth = 0; node && depth < 6; node = node.parentElement, depth++) {
        const lines = (node.innerText || "").split("\n").map(s => s.trim()).filter(Boolean);
        if (!dueText) {
          // The To-do list writes due text without a "Due" prefix ("Tomorrow, 8:00 AM",
          // "Thursday, 11:59 PM", "Nov 4", "11/10"), so match those shapes too.
          const due = lines.find(l =>
            /^(Due\b|No due date$)/i.test(l)
            || /^(Today|Tomorrow|Yesterday)\b/i.test(l)
            || /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\b/i.test(l)
            || /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d/i.test(l)
            || /^\d{1,2}\/\d{1,2}\b/.test(l)
            || /\b\d{1,2}(:\d{2})?\s*[AP]M\b/i.test(l));
          if (due) dueText = due;
        }
        if (!statusLabel) {
          const st = lines.find(l => STATUS_WORD.test(l) || /\blate\b/i.test(l));
          if (st) statusLabel = st;
        }
        // The class name is a line that isn't the title, the due text, or a status word.
        const candidate = lines.find(l => l !== title && !/^(Due\b|No due date$)/i.test(l)
          && l.length <= 80 && !/^\d/.test(l) && !STATUS_WORD.test(l));
        if (candidate && courseName === "Classroom") courseName = candidate;
        if (dueText && courseName !== "Classroom") break;
      }

      items.set(assignmentId, {
        courseId: m[1], courseName, id: assignmentId, title,
        url: url.origin + url.pathname, dueText,
        status: statusKey,
        statusLabel,
        late: /\blate\b/i.test(statusLabel || "")
      });
    }
    return [...items.values()];
  }

  function loadItems() {
    try { return JSON.parse(sessionStorage.getItem(K_ITEMS) || "[]"); } catch { return []; }
  }
  function saveItems(arr) { sessionStorage.setItem(K_ITEMS, JSON.stringify(arr)); }
  function clearState() {
    sessionStorage.removeItem(K_ITEMS);
    sessionStorage.removeItem(K_PHASE);
    sessionStorage.removeItem(K_START);
  }

  function gotoNextPhase() {
    sessionStorage.setItem(K_PHASE, String(phase + 1));
    location.href = location.origin + uSeg + PHASES[phase + 1].path + "?classly-sync#classly-sync";
  }

  async function finish(allItems) {
    clearState();
    // Nothing found on the page — report that cleanly instead of sending an empty payload
    // the app would reject as a save error. Lets Classly show a "found nothing" hint.
    if (!allItems.length) {
      location.href = SYNC_SCHEME + "?count=0";
      return;
    }
    try {
      const reply = await browser.runtime.sendMessage({ kind: "classly-import", items: allItems });
      if (!reply || !reply.ok) throw new Error((reply && reply.error) || "Import failed.");
    } catch (e) {
      return bail(e.message || "Could not reach Classly.");
    }
    location.href = SYNC_SCHEME + "?count=" + allItems.length;
  }

  function bail(msg) {
    clearState();
    location.href = SYNC_SCHEME + "?error=" + encodeURIComponent(msg);
  }

  // Merge this phase's items in, then move to the next list or finish.
  function advance(scraped) {
    const merged = loadItems();
    const seen = new Set(merged.map(i => i.id));
    for (const it of scraped) if (!seen.has(it.id)) merged.push(it);
    saveItems(merged);
    if (phase + 1 < PHASES.length) return gotoNextPhase();
    return finish(merged);
  }

  // The list renders after load; poll until items appear. The "Done" list can legitimately be
  // empty, so only phase 0 must find something before we give up waiting.
  function attempt() {
    // Account discovery: before scraping, make sure we're on the account that actually has work.
    if (!sessionStorage.getItem(K_ACCT)) {
      const items = scrape("not-turned-in");
      if (items.length > 0) {                       // this account has assignments — lock it in
        uSeg = "/u/" + currentUIndex();
        sessionStorage.setItem(K_ACCT, uSeg);
        return advance(items);                      // phase 0 (not-turned-in) is done here
      }
      if (Date.now() - started < 4500) return setTimeout(attempt, 600);   // give it time to render
      const idx = currentUIndex();
      if (idx + 1 < MAX_ACCT) return gotoAccount(idx + 1);                 // try the next account
      uSeg = "/u/" + idx;                            // none had work — give up, finish empty
      sessionStorage.setItem(K_ACCT, uSeg);
      return advance([]);
    }

    const current = PHASES[phase] || PHASES[0];
    const scraped = scrape(current.key);
    if (scraped.length || phase > 0) return advance(scraped);
    if (Date.now() - started > 9000) return advance([]);   // phase 0 genuinely empty
    setTimeout(attempt, 600);
  }

  attempt();
})();

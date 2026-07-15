/* Evidence-backed DOM helpers for the Semantouch demo.
   Requires window.__SEMANTOUCH_DEMO_EVIDENCE__ (from demo-evidence.js).
   Refuse sample / incomplete evidence at composition load. */

(function () {
  const REQUIRED_FRAMES = 7;
  const REQUIRED_TOOLS = 16;

  function fail(message) {
    const err = new Error(`[semantouch-demo] ${message}`);
    console.error(err.message);
    throw err;
  }

  function getEvidence() {
    const e = window.__SEMANTOUCH_DEMO_EVIDENCE__;
    if (!e) fail("missing window.__SEMANTOUCH_DEMO_EVIDENCE__ — run: node scripts/record-demo-evidence.mjs");
    if (e.sample === true) fail("sample evidence refused");
    if (!e.tools || e.tools.count !== REQUIRED_TOOLS) {
      fail(`tools.count must be ${REQUIRED_TOOLS}, got ${e.tools && e.tools.count}`);
    }
    if (!Array.isArray(e.sequence) || e.sequence.length !== REQUIRED_FRAMES) {
      fail(`sequence must have ${REQUIRED_FRAMES} frames`);
    }
    if (!e.integrity || !e.integrity.digest) fail("missing integrity.digest");
    return e;
  }

  function frameById(id) {
    const e = getEvidence();
    const step = e.sequence.find((s) => s.id === id);
    if (!step) fail(`unknown frame id: ${id}`);
    return step;
  }

  function claim(step, key) {
    const found = (step.claims || []).find((c) => c.key === key);
    if (!found) fail(`frame ${step.id} missing claim ${key}`);
    return found.value;
  }

  function claimOr(step, key, fallback) {
    const found = (step.claims || []).find((c) => c.key === key);
    return found ? found.value : fallback;
  }

  function text(el, value) {
    if (!el) return;
    el.textContent = value == null ? "—" : String(value);
  }

  function setHTML(el, html) {
    if (!el) return;
    el.textContent = "";
    el.appendChild(document.createTextNode(html));
  }

  /** Decorative virtual cursor SVG (never gates actions). */
  function cursorSVG() {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 28 28");
    svg.setAttribute("width", "28");
    svg.setAttribute("height", "28");
    const path = document.createElementNS(ns, "path");
    path.setAttribute(
      "d",
      "M4 3 L4 22 L9.5 16.5 L13 24 L16 22.5 L12.5 15 L20 15 Z",
    );
    path.setAttribute("fill", "#4DF545");
    path.setAttribute("stroke", "#173D2A");
    path.setAttribute("stroke-width", "1.2");
    path.setAttribute("stroke-linejoin", "round");
    svg.appendChild(path);
    return svg;
  }

  function mountCursor(host) {
    const wrap = document.createElement("div");
    wrap.className = "cursor";
    wrap.appendChild(cursorSVG());
    host.appendChild(wrap);
    return wrap;
  }

  window.__SemantouchDemo = {
    getEvidence,
    frameById,
    claim,
    claimOr,
    text,
    setHTML,
    mountCursor,
    REQUIRED_TOOLS,
  };
})();

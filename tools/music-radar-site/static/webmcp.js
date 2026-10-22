// WebMCP tools for the AI Music Radar site (music.grepawk.com; see tools/music-radar-site/README.md, "WebMCP").
// Registers in-page tools for browser agents through the WebMCP proposal (github.com/webmachinelearning/webmcp).
// Does nothing unless the browser exposes modelContext (document.modelContext per the current spec,
// navigator.modelContext in older drafts). Off switch: remove the <script> tag, or open the page with ?nowebmcp.
(() => {
  "use strict";
  if (new URLSearchParams(location.search).has("nowebmcp")) return;
  const ctx = (typeof document !== "undefined" && document.modelContext) || (typeof navigator !== "undefined" && navigator.modelContext);
  if (!ctx) return;
  const DEMO = "https://grepawk.com/music-hear/";
  const text = (v) => ({ content: [{ type: "text", text: typeof v === "string" ? v : JSON.stringify(v) }] });
  const obj = (props, required) => ({ type: "object", properties: props || {}, required: required || [], additionalProperties: false });
  const clean = (s) => String(s || "").replace(/\s+/g, " ").trim();
  const tools = [];
  const tool = (name, description, inputSchema, run, readOnly) => tools.push(Object.assign({
    name, description, inputSchema,
    async execute(input, client) { try { return await run(input || {}, client); } catch (e) { return { isError: true, content: [{ type: "text", text: "Error: " + String((e && e.message) || e) }] }; } },
  }, readOnly ? { annotations: { readOnlyHint: true } } : {}));
  const sections = () => Array.from(document.querySelectorAll("section[id], div[id='video']")).map((s) => s.id);

  tool("musicradar.app_info", "What AI Music Radar is: name, description, platforms, pricing plans, App Store link and the free web demo URL.", obj(), async () => {
    let ld = {}; try { ld = JSON.parse(document.querySelector('script[type="application/ld+json"]').textContent); } catch (e) {}
    const store = Array.from(document.links).find((a) => /apps\.apple\.com/.test(a.href));
    return text({ name: ld.name, description: ld.description, platforms: ld.operatingSystem, offers: (ld.offers || []).map((o) => ({ name: o.name, price: o.price, currency: o.priceCurrency })),
      appStore: store ? store.href : undefined, webDemo: DEMO, sections: sections() });
  }, true);
  tool("musicradar.read_section", "Read the text of one page section (e.g. how, pricing, screenshots).", obj({ section: { type: "string", description: "Section id, see musicradar.app_info" } }, ["section"]), async ({ section }) => {
    const el = document.getElementById(section); if (!el) return text("No such section. Sections: " + sections().join(", "));
    return text(clean(el.innerText).slice(0, 4000));
  }, true);
  tool("musicradar.go_to_section", "Scroll the page to a section so the user sees it.", obj({ section: { type: "string" } }, ["section"]), async ({ section }) => {
    const el = document.getElementById(section); if (!el) return text("No such section. Sections: " + sections().join(", "));
    el.scrollIntoView({ behavior: "smooth", block: "start" }); return text("Showing " + section);
  });
  tool("musicradar.play_video", "Play (or pause) the explainer video on the page.", obj({ pause: { type: "boolean" } }), async ({ pause }) => {
    const v = document.querySelector("#video video, video"); if (!v) return text("No video on this page.");
    v.scrollIntoView({ behavior: "smooth", block: "center" });
    if (pause) { v.pause(); return text("Paused."); }
    v.muted = true; await v.play().catch(() => {}); return text(v.paused ? "Could not autoplay; the user can press play." : "Playing (muted).");
  });
  tool("musicradar.open_web_demo", "Open the free in-browser demo (listens to the microphone and writes notes live) in a new tab.", obj(), async () => {
    window.open(DEMO, "_blank", "noopener"); return text("Opened " + DEMO);
  });

  const controller = new AbortController(), registered = [];
  (async () => {
    if (typeof ctx.registerTool === "function") {
      for (const t of tools) {
        try { await ctx.registerTool(t, { signal: controller.signal }); registered.push(t.name); }
        catch (e) { try { await ctx.registerTool(t); registered.push(t.name); } catch (e2) { console.warn("[webmcp] registerTool failed", t.name, e2); } }
      }
    } else if (typeof ctx.provideContext === "function") {
      try { await ctx.provideContext({ tools }); tools.forEach((t) => registered.push(t.name)); } catch (e) { console.warn("[webmcp] provideContext failed", e); }
    }
  })();
  window.musicRadarWebMCP = { tools, registered, unregister: () => controller.abort() };
})();

// WebMCP tools for the AI Music Radar web demo (grepawk.com/music-hear/; docs/webmcp.md). Registers in-page
// tools for browser agents through the WebMCP proposal (github.com/webmachinelearning/webmcp). Does nothing
// unless the browser exposes modelContext (document.modelContext per the current spec, navigator.modelContext
// in older drafts). Off switch: remove the <script> tag, or open the page with ?nowebmcp.
// The tools call window.__earsheet.api, the same handlers the page's buttons use. Everything stays in the
// browser; no server endpoints are involved.
(() => {
  "use strict";
  if (new URLSearchParams(location.search).has("nowebmcp")) return;
  const ctx = (typeof document !== "undefined" && document.modelContext) || (typeof navigator !== "undefined" && navigator.modelContext);
  if (!ctx) return;

  const text = (v) => ({ content: [{ type: "text", text: typeof v === "string" ? v : JSON.stringify(v === undefined ? null : v) }] });
  const fail = (e) => ({ isError: true, content: [{ type: "text", text: "Error: " + String((e && e.message) || e) }] });
  async function confirmUser(client, msg) {
    try {
      if (client && typeof client.requestUserInteraction === "function")
        return !!(await client.requestUserInteraction(async () => window.confirm(msg)));
    } catch (e) { /* fall through */ }
    return window.confirm(msg);
  }
  const S = () => window.__earsheet;
  const ready = () => new Promise((ok, bad) => {
    const t0 = Date.now();
    (function poll() {
      const s = S();
      if (s && s.ready && s.api && s.api.runFile) return ok(s);
      if (s && s.error) return bad(new Error(s.error));
      if (Date.now() - t0 > 60000) return bad(new Error("The transcription engine is not ready yet"));
      setTimeout(poll, 200);
    })();
  });
  // Replacing an unsaved take (new file, sample or recording) asks first, like the page's Re-record button.
  const guardTake = async (client, what, fn) => {
    const s = S();
    if (s && s.notes && s.notes.length && !s.exported && !(await confirmUser(client, `${what} replaces the current take, which isn't saved (Download MIDI first to keep it). Continue?`)))
      return text("Cancelled by the user.");
    return fn();
  };
  const summary = (s, max) => {
    const notes = (s.lastResult && s.lastResult.notes) || [];
    let sheet = null; try { sheet = s.api.currentSheet(); } catch (e) {}
    return {
      ready: !!s.ready, backend: s.backend, recording: !!s.live, view: s.view, audioLoaded: !!s.audio,
      noteCount: notes.length, tempoOverride: s.tempoOverride,
      sheet: sheet ? { bpm: sheet.bpm, meter: sheet.meter, key: s.api.keyName ? s.api.keyName(sheet.key) : sheet.key } : undefined,
      droppedQuiet: s.droppedQuiet, exported: !!s.exported,
      notes: notes.slice(0, max === undefined ? 200 : max),
    };
  };

  const obj = (props, required) => ({ type: "object", properties: props || {}, required: required || [], additionalProperties: false });
  const tools = [];
  const tool = (name, description, inputSchema, run, readOnly) => tools.push(Object.assign({
    name, description, inputSchema,
    async execute(input, client) { try { return await run(input || {}, client); } catch (e) { return fail(e); } },
  }, readOnly ? { annotations: { readOnlyHint: true } } : {}));

  tool("musichear.get_results", "Detected notes (midi, name, onset/offset seconds, velocity) for the current take, plus engine state, view, and tempo/meter/key when the sheet analysis has run (see musichear.analyze_sheet).",
    obj({ maxNotes: { type: "number", description: "Max notes to return (default 200)" } }), async ({ maxNotes }) => text(summary(S() || {}, maxNotes)), true);
  tool("musichear.load_sample", "Load the built-in sample (C major scale + triad) and transcribe it to notes. Replaces an unsaved take only after the user confirms.",
    obj(), async (_, client) => { const s = await ready(); return guardTake(client, "Loading the sample", async () => { await s.api.loadSample(); return text(summary(s, 50)); }); });
  tool("musichear.transcribe_url", "Fetch a same-origin audio or video file (first 60 s or so) and transcribe it to notes. Replaces an unsaved take only after the user confirms.",
    obj({ url: { type: "string", description: "Same-origin URL, e.g. /sampaudio.mp3" } }, ["url"]),
    async ({ url }, client) => {
      const u = new URL(url, location.href); if (u.origin !== location.origin) throw new Error("Only same-origin URLs are allowed");
      const s = await ready();
      return guardTake(client, "Transcribing a new file", async () => {
        const r = await fetch(u); if (!r.ok) throw new Error("HTTP " + r.status);
        await s.api.loadAudio(await r.blob(), u.pathname.split("/").pop()); await s.api.runFile(); return text(summary(s, 50));
      });
    });
  tool("musichear.retranscribe", "Run the transcription again on the loaded audio (e.g. after changing thresholds on the page).",
    obj(), async () => { const s = await ready(); if (!s.audio) return text("No audio loaded."); await s.api.runFile(); return text(summary(s, 50)); });
  tool("musichear.start_recording", "Start live listening from the microphone (the browser asks for mic permission); notes appear as the user plays, sings or hums. Replaces an unsaved take only after the user confirms.",
    obj(), async (_, client) => { const s = await ready(); if (s.live) return text("Already recording.");
      return guardTake(client, "Recording", async () => { await s.api.startLive(); return text(S().live ? "Recording. Call musichear.stop_recording to finish." : "Could not start the microphone."); }); });
  tool("musichear.stop_recording", "Stop live listening and finalize the notes.", obj(),
    async () => { const s = await ready(); if (!s.live) return text("Not recording."); await s.api.stopLive(); return text(summary(s, 50)); });
  tool("musichear.play", "Play the detected notes (synth) or the original audio.", obj({ source: { type: "string", enum: ["notes", "original"], description: "Default notes" } }),
    async ({ source }) => { const s = await ready(); if (!s.notes.length && source !== "original") return text("No notes to play.");
      (source === "original" ? s.api.playOriginal : s.api.playNotes)(); return text("Playing " + (source || "notes") + "."); });
  tool("musichear.stop", "Stop playback.", obj(), async () => { (await ready()).api.stop(); return text("Stopped."); });
  tool("musichear.set_view", "Show the piano roll or the sheet-music page.", obj({ view: { type: "string", enum: ["roll", "page"] } }, ["view"]),
    async ({ view }) => { const s = await ready(); s.api.setView(view); return text("View: " + view); });
  tool("musichear.set_tempo", "Set the sheet tempo in BPM (used for quantization, the page view and MIDI), or omit bpm to go back to the estimate.",
    obj({ bpm: { type: "number", description: "Beats per minute; omit to use the estimate" } }),
    async ({ bpm }) => { const s = await ready(); s.api.setTempo(bpm === undefined ? null : bpm); return text({ tempoOverride: s.tempoOverride }); });
  tool("musichear.analyze_sheet", "Run the sheet analysis (tempo, meter, key, quantization) for the current notes and return it.", obj(),
    async () => { const s = await ready(); if (!s.notes.length) return text("No notes yet."); const sc = s.api.sheetScore();
      return text({ bpm: sc.bpm, meter: sc.meter, key: s.api.keyName ? s.api.keyName(sc.key) : sc.key, tempoOverride: s.tempoOverride }); });
  tool("musichear.download_midi", "Export the transcription as a MIDI file download. Asks the user to confirm.", obj(),
    async (_, client) => { const s = await ready(); if (!s.notes.length) return text("No notes to export.");
      if (!(await confirmUser(client, "Download the transcription as a MIDI file?"))) return text("Cancelled by the user.");
      s.api.downloadMidi(); return text("Downloaded earsheet-transcription.mid"); });

  // Register. Current spec: registerTool(tool, {signal}) (may return a promise). Older drafts: provideContext({tools}).
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
  window.musicHearWebMCP = { tools, registered, unregister: () => controller.abort() };
})();

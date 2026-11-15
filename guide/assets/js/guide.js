/* GT Termin Business Owner Guide — one step at a time, progress saved on this device. Works from file:// too. */
(function () {
  "use strict";
  var G = window.GTG;
  var STEPS = G.steps;
  var TOTAL = STEPS.length;
  var KEY = "gtg.state.v1";
  var LANGS = ["mk", "en", "sq"];

  var state = load();

  function load() {
    var s = { lang: "mk", step: 1, done: [] };
    try {
      var raw = JSON.parse(localStorage.getItem(KEY) || "null");
      if (raw && typeof raw === "object") {
        if (LANGS.indexOf(raw.lang) >= 0) s.lang = raw.lang;
        if (raw.step >= 1 && raw.step <= TOTAL) s.step = raw.step;
        if (Array.isArray(raw.done)) s.done = raw.done.filter(function (id) { return STEPS.some(function (st) { return st.id === id; }); });
      }
    } catch (e) { /* storage unavailable: defaults */ }
    var m = /^#\/step\/(\d)$/.exec(location.hash || "");
    if (m && +m[1] >= 1 && +m[1] <= TOTAL) s.step = +m[1];
    return s;
  }
  function save() {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* ignore */ }
  }

  /* ---------- text helpers ---------- */
  function tr(obj) { return obj ? (obj[state.lang] || obj.mk || "") : ""; }
  function ui(key, vars) {
    var s = (G.ui[state.lang] && G.ui[state.lang][key]) || G.ui.mk[key] || "";
    if (vars) Object.keys(vars).forEach(function (k) { s = s.split("{" + k + "}").join(vars[k]); });
    return s;
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function rich(s) {
    return esc(s)
      .replace(/\[\[(.+?)\]\]/g, '<span class="chip">$1</span>')
      .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  }
  function isDone(id) { return state.done.indexOf(id) >= 0; }

  /* ---------- icons ---------- */
  var ICONS = {
    chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
    bell: '<path d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8"/><path d="M10 20a2 2 0 0 0 4 0"/>',
    palette: '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="10" r="1.2"/><circle cx="12" cy="7.5" r="1.2"/><circle cx="16" cy="10" r="1.2"/><path d="M12 21c-1.5 0-2-1-2-2s1-2 2-2h1.5a2.5 2.5 0 0 0 0-5"/>',
    card: '<rect x="2.5" y="5" width="19" height="14" rx="2.5"/><path d="M2.5 10h19M6 15h4"/>',
    help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6V14"/><circle cx="12" cy="17" r=".6"/>'
  };
  function icon(name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || "") + "</svg>";
  }

  /* ---------- screenshots ---------- */
  function shotHtml(shot) {
    if (!shot) return "";
    if (shot.needed) {
      return '<figure class="shot"><div class="needed" role="img" aria-label="' + esc(ui("neededTag") + ": " + tr(shot.needed)) + '">' +
        '<span class="needed__tag">' + esc(ui("neededTag")) + "</span>" +
        '<span class="needed__what">' + esc(tr(shot.needed)) + "</span>" +
        '<span class="needed__text">' + esc(ui("neededText")) + "</span></div></figure>";
    }
    var w = shot.size[0], h = shot.size[1];
    var markers = (shot.markers || []).map(function (r) {
      return '<span class="marker" style="left:' + (r[0] / w * 100) + "%;top:" + (r[1] / h * 100) + "%;width:" + ((r[2] - r[0]) / w * 100) + "%;height:" + ((r[3] - r[1]) / h * 100) + '%"></span>';
    }).join("");
    return '<figure class="shot"><button type="button" class="phone" data-zoom aria-label="' + esc(ui("zoom")) + '">' +
      '<span class="phone__screen"><img src="' + esc(tr(shot.src)) + '" alt="" width="' + w + '" height="' + h + '" loading="lazy" decoding="async" />' + markers + "</span></button>" +
      (shot.src[state.lang] ? "" : '<figcaption class="shot__note">' + esc(ui("shotInMk")) + "</figcaption>") + "</figure>";
  }

  /* ---------- render ---------- */
  function applyUi() {
    document.documentElement.lang = state.lang;
    document.title = ui("docTitle");
    document.querySelectorAll("[data-ui]").forEach(function (el) { el.textContent = ui(el.getAttribute("data-ui")); });
    document.querySelectorAll("[data-ui-label]").forEach(function (el) { el.setAttribute("aria-label", ui(el.getAttribute("data-ui-label"))); });
    document.querySelectorAll("[data-lang]").forEach(function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-lang") === state.lang)); });
    document.getElementById("zoomClose").textContent = ui("close");
  }

  function renderHero() {
    var cta = document.getElementById("heroCta");
    var started = state.done.length > 0 || state.step > 1;
    cta.textContent = started && state.done.length < TOTAL ? ui("heroContinue", { n: state.step }) : ui("heroStart");
  }

  function renderProgress() {
    var n = state.done.length;
    document.getElementById("progressFill").style.width = (n / TOTAL * 100) + "%";
    document.getElementById("progressText").textContent = ui("progress", { done: n, total: TOTAL });
    document.getElementById("stepper").innerHTML = STEPS.map(function (st, i) {
      var num = i + 1;
      var done = isDone(st.id);
      return '<button type="button" data-step="' + num + '"' + (num === state.step ? ' aria-current="step"' : "") + (done ? ' class="is-done"' : "") +
        ' aria-label="' + esc(ui("stepOf", { n: num, total: TOTAL }) + ": " + tr(st.title) + (done ? " (" + ui("done") + ")" : "")) + '">' +
        '<span class="stepper__dot">' + (done ? "✓" : num) + '</span><span class="stepper__label">' + esc(tr(st.short || st.title)) + "</span></button>";
    }).join("");
  }

  function renderStep(animate) {
    var st = STEPS[state.step - 1];
    var el = document.getElementById("step");
    var cards = st.cards.map(function (c, i) {
      var ex = "";
      if (c.example) {
        ex = '<dl class="example"><span class="example__title">' + esc(ui("example")) + "</span>" +
          tr(c.example).map(function (row) { return "<dt>" + esc(row[0]) + "</dt><dd>" + esc(row[1]) + "</dd>"; }).join("") + "</dl>";
      }
      var tip = c.tip ? '<p class="callout"><strong class="callout__label">' + esc(ui("tip")) + "</strong>" + rich(tr(c.tip)) + "</p>" : "";
      return '<section class="card' + (c.shot ? "" : " card--noshot") + '"><div class="card__body">' +
        '<h3 class="card__title"><span class="card__num">' + (i + 1) + "</span>" + esc(tr(c.title)) + "</h3>" +
        '<p class="card__text">' + rich(tr(c.text)) + "</p>" + ex + tip + "</div>" + shotHtml(c.shot) + "</section>";
    }).join("");
    var note = st.note ? '<p class="callout callout--note"><strong class="callout__label">' + esc(ui("good")) + "</strong>" + rich(tr(st.note)) + "</p>" : "";
    el.innerHTML = '<header class="step__head"><div class="step__meta">' + esc(ui("stepOf", { n: state.step, total: TOTAL })) + " · " + esc(ui("minutes", { n: st.minutes })) + "</div>" +
      '<h2 class="step__title">' + esc(tr(st.title)) + '</h2><p class="step__lead">' + esc(tr(st.lead)) + "</p></header>" +
      '<div class="cards">' + cards + "</div>" + note;
    if (animate) {
      el.classList.remove("is-entering");
      void el.offsetWidth;
      el.classList.add("is-entering");
    }
    renderPager();
  }

  function renderPager() {
    var st = STEPS[state.step - 1];
    var done = isDone(st.id);
    var last = state.step === TOTAL;
    var html = "";
    html += state.step > 1 ? '<button type="button" class="btn btn--ghost prev" data-act="prev">← ' + esc(ui("prev")) + "</button>" : "<span></span>";
    html += '<div class="pager__group">';
    html += '<button type="button" class="btn ' + (done ? "btn--done" : "btn--ghost") + '" data-act="toggle" aria-pressed="' + done + '">' + (done ? "✓ " + esc(ui("done")) : esc(ui("markDone"))) + "</button>";
    html += '<button type="button" class="btn btn--primary" data-act="next">' + (last ? esc(ui("finish")) : esc(ui("next")) + " →") + "</button>";
    html += "</div>";
    if (state.done.length === TOTAL) {
      html += '<div class="finish" style="flex-basis:100%"><h3>' + esc(ui("allDone")) + "</h3><p>" + esc(ui("allDoneLead")) + '</p><button type="button" class="linkbtn" data-act="reset">' + esc(ui("reset")) + "</button></div>";
    }
    document.getElementById("pager").innerHTML = html;
  }

  function renderMore() {
    document.getElementById("moreGrid").innerHTML = G.more.map(function (f) {
      return '<article class="feature"><span class="feature__icon">' + icon(f.icon) + "</span><div><h3>" + esc(tr(f.title)) + "</h3><p>" + rich(tr(f.text)) + "</p></div></article>";
    }).join("");
    document.getElementById("faqList").innerHTML = G.faq.map(function (f) {
      return "<details><summary>" + esc(tr(f.q)) + "</summary><p>" + rich(tr(f.a)) + "</p></details>";
    }).join("");
  }

  function renderAll(animate) {
    applyUi();
    renderHero();
    renderProgress();
    renderStep(animate);
    renderMore();
  }

  /* ---------- actions ---------- */
  function goTo(n, scroll) {
    if (n < 1 || n > TOTAL) return;
    var changed = n !== state.step;
    state.step = n;
    save();
    if (history.replaceState) history.replaceState(null, "", "#/step/" + n);
    renderHero();
    renderProgress();
    renderStep(changed);
    if (scroll) {
      var j = document.getElementById("journey");
      var top = j.getBoundingClientRect().top + window.pageYOffset - 70;
      window.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
      document.getElementById("step").focus({ preventScroll: true });
    }
  }
  function setDone(id, value) {
    var has = isDone(id);
    if (value && !has) state.done.push(id);
    if (!value && has) state.done = state.done.filter(function (x) { return x !== id; });
    save();
  }

  document.addEventListener("click", function (e) {
    var t = e.target.closest("button, a");
    if (!t) return;
    if (t.hasAttribute("data-lang")) {
      state.lang = t.getAttribute("data-lang");
      save();
      renderAll(false);
      return;
    }
    if (t.id === "heroCta") { goTo(state.step, true); return; }
    if (t.hasAttribute("data-step")) { goTo(+t.getAttribute("data-step"), false); return; }
    var act = t.getAttribute("data-act");
    var st = STEPS[state.step - 1];
    if (act === "prev") { goTo(state.step - 1, true); return; }
    if (act === "toggle") { setDone(st.id, !isDone(st.id)); renderProgress(); renderPager(); renderHero(); return; }
    if (act === "next") {
      setDone(st.id, true);
      if (state.step < TOTAL) goTo(state.step + 1, true);
      else { renderProgress(); renderPager(); renderHero(); }
      return;
    }
    if (act === "reset") { state.done = []; save(); goTo(1, true); return; }
    if (t.hasAttribute("data-zoom")) {
      var dlg = document.getElementById("zoom");
      document.getElementById("zoomBody").innerHTML = t.outerHTML.replace("data-zoom", "data-zoomed").replace('class="phone"', 'class="phone" tabindex="-1"');
      if (typeof dlg.showModal === "function") dlg.showModal();
      return;
    }
  });
  var zoom = document.getElementById("zoom");
  document.getElementById("zoomClose").addEventListener("click", function () { zoom.close(); });
  zoom.addEventListener("click", function (e) { if (e.target === zoom) zoom.close(); });

  document.getElementById("stepper").addEventListener("keydown", function (e) {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    e.preventDefault();
    var n = state.step + (e.key === "ArrowRight" ? 1 : -1);
    goTo(n, false);
    var b = document.querySelector('#stepper [data-step="' + state.step + '"]');
    if (b) b.focus();
  });
  window.addEventListener("hashchange", function () {
    var m = /^#\/step\/(\d)$/.exec(location.hash || "");
    if (m) goTo(+m[1], false);
  });

  renderAll(false);
})();

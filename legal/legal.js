(function () {
  var params = new URLSearchParams(location.search);
  var supported = ["en", "mk", "sq"];
  var lang = params.get("lang");
  if (supported.indexOf(lang) === -1) {
    var nav = (navigator.language || "en").slice(0, 2).toLowerCase();
    lang = supported.indexOf(nav) === -1 ? "en" : nav;
  }
  document.documentElement.lang = lang;
  document.querySelectorAll("main[data-lang]").forEach(function (el) {
    el.hidden = el.getAttribute("data-lang") !== lang;
  });
  document.querySelectorAll(".lang a").forEach(function (a) {
    a.setAttribute("aria-current", a.getAttribute("data-lang") === lang ? "true" : "false");
  });
  var visible = document.querySelector('main[data-lang="' + lang + '"] h1');
  if (visible) document.title = visible.textContent;
  // Inside the app the sheet provides its own header and language.
  if (params.get("embed") === "1") document.body.classList.add("embedded");
  var theme = params.get("theme");
  if (theme === "dark" || theme === "light") document.documentElement.setAttribute("data-theme", theme);
  if (params.get("style") === "classic") document.documentElement.setAttribute("data-style", "classic");
})();

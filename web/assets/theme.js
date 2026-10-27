// The theme toggle. The page opens light unless the visitor chose dark here before; the choice
// is applied by the inline snippet in <head> so the page never flashes the wrong scheme.
(function () {
  var root = document.documentElement;
  var button = document.querySelector(".theme-toggle");
  if (!button) return;

  function sync() {
    var dark = root.getAttribute("data-theme") === "dark";
    button.setAttribute("aria-pressed", String(dark));
    button.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", dark ? "#000000" : "#f2f2f7");
  }

  button.addEventListener("click", function () {
    var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("embers-theme", next); } catch (e) {}
    sync();
  });

  sync();
})();

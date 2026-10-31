// The App Store links and the GitHub repository, in one place. Until the listing exists these are empty, and every store
// button stays marked "Soon" and goes nowhere. Fill them in and the buttons come alive on every page.
var EMBERS_STORE = {
  ios: "https://apps.apple.com/app/id6824939307",
  mac: "https://apps.apple.com/app/id6824939307?platform=mac"
};

// "owner/name" once the repository is public. Empty, the GitHub links point at a placeholder and
// the header badge shows no count.
var EMBERS_REPO = "helshabini/embers";

(function () {
  document.querySelectorAll("[data-store]").forEach(function (link) {
    var url = EMBERS_STORE[link.getAttribute("data-store")];
    if (url) {
      link.href = url;
      link.removeAttribute("aria-disabled");
      var soon = link.querySelector(".soon");
      if (soon) soon.remove();
    } else {
      link.addEventListener("click", function (event) { event.preventDefault(); });
      link.setAttribute("title", "Coming soon to the App Store");
    }
  });
})();

(function () {
  if (!EMBERS_REPO) return;
  var base = "https://github.com/" + EMBERS_REPO;
  document.querySelectorAll("[data-repo-link]").forEach(function (link) {
    var sub = link.getAttribute("data-repo-link");
    link.href = sub ? base + "/" + sub : base;
  });

  var count = document.querySelector("[data-stars]");
  if (!count) return;
  // Unauthenticated, GitHub allows 60 requests an hour per visitor, so the count is kept for an
  // hour rather than asked for on every page view.
  var key = "embers-stars", cached = null;
  try { cached = JSON.parse(localStorage.getItem(key) || "null"); } catch (e) {}
  function show(n) {
    count.textContent = n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n);
    count.hidden = false;
    count.setAttribute("aria-label", n + " stars");
  }
  if (cached && cached.repo === EMBERS_REPO && Date.now() - cached.at < 3600000) return show(cached.stars);
  fetch("https://api.github.com/repos/" + EMBERS_REPO)
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (repo) {
      show(repo.stargazers_count);
      try { localStorage.setItem(key, JSON.stringify({ repo: EMBERS_REPO, stars: repo.stargazers_count, at: Date.now() })); } catch (e) {}
    })
    .catch(function () { if (cached && cached.repo === EMBERS_REPO) show(cached.stars); });
})();

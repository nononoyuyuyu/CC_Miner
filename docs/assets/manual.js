(function () {
  "use strict";
  var path = window.location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll("a[data-page]").forEach(function (link) {
    if (link.getAttribute("href") === path) link.setAttribute("aria-current", "page");
  });
  document.querySelectorAll("details.nav-toggle").forEach(function (menu) {
    menu.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        menu.removeAttribute("open");
        var summary = menu.querySelector("summary");
        if (summary) summary.focus();
      }
    });
  });
}());

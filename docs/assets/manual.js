(function () {
  "use strict";
  var current = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll("a[data-page]").forEach(function (link) {
    if (link.getAttribute("href") === current) link.setAttribute("aria-current", "page");
  });
  document.querySelectorAll("details.nav-toggle").forEach(function (menu) {
    menu.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && menu.open) {
        menu.open = false;
        menu.querySelector("summary").focus();
      }
    });
  });
})();

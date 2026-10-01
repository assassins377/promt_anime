import "phoenix_html";
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import Alpine from "../vendor/alpine.esm.js";
import "../css/app.css";
import "../css/public_header.css";
import {AdminTable, scrollPatchedAdminTable} from "./admin_table.mjs";
import {adminShell} from "./admin_shell.mjs";
import {publicDropdown, siteHeader} from "./public_header.mjs";

Alpine.data("publicDropdown", publicDropdown);
Alpine.data("siteHeader", siteHeader);
document.fonts?.load('400 24px "Material Symbols Rounded"').then(fonts => {
  if (fonts.length) document.documentElement.classList.add("symbols-ready");
}).catch(() => {});

Alpine.store("theme", {
  value: (() => { try { return localStorage.getItem("anime-theme") || "system"; } catch (_) { return "system"; } })(),
  set(value) {
    this.value = value;
    try { localStorage.setItem("anime-theme", value); } catch (_) {}
    document.documentElement.dataset.theme = value === "dark" || (value === "system" && matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light";
  }
});
Alpine.data("adminShell", adminShell);
Alpine.data("adminFilters", () => ({
  expanded: true,
  init() {
    this.media = matchMedia("(min-width: 768px)");
    this.sync = () => { this.expanded = this.media.matches; };
    this.sync();
    this.media.addEventListener("change", this.sync);
  },
  destroy() { this.media.removeEventListener("change", this.sync); }
}));
Alpine.start();
window.addEventListener("phx:admin:locale", event => { document.documentElement.lang = event.detail.locale; });
window.addEventListener("phx:page-loading-stop", scrollPatchedAdminTable);
const csrfToken = document.querySelector("meta[name=csrf-token]").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {AdminTable},
  params: {_csrf_token: csrfToken},
  dom: {onBeforeElUpdated(from, to) { if (from._x_dataStack) Alpine.clone(from, to); }}
});
liveSocket.connect();

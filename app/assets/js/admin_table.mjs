// Holds the measured scroll-region height while server-side list tasks run.
// This hook never fetches data or makes authorization decisions.
export const AdminTable = {
  mounted() {
    this.lastHeight = this.el.getBoundingClientRect().height;
    this.wasLoading = false;
    this.updated();
  },
  beforeUpdate() {
    if (this.el.getAttribute("aria-busy") !== "true") {
      this.lastHeight = this.el.getBoundingClientRect().height;
    }
  },
  updated() {
    const loading = this.el.getAttribute("aria-busy") === "true";
    if (loading) {
      this.el.style.minHeight = `min(${Math.max(0, this.lastHeight)}px, 65vh)`;
    } else {
      this.el.style.removeProperty("min-height");
      if (this.wasLoading) {
        this.el.scrollTop = 0;
        // Keep a focused search/filter visible while its results update.
        if (!editingFilter()) this.el.scrollIntoView({block: "start"});
      }
      this.lastHeight = this.el.getBoundingClientRect().height;
    }
    this.wasLoading = loading;
  }
};

function editingFilter(doc = document) {
  return Boolean(doc.activeElement?.closest(".admin-filters"));
}

// Synchronous nested tables have no hook. Async lists scroll only after their
// replacement rows arrive, not once at patch time and again at completion.
export function scrollPatchedAdminTable(event, doc = document) {
  if (event.detail.kind !== "patch" || editingFilter(doc)) return;
  const region = doc.querySelector("#admin-content .admin-table-wrap");
  if (!region || region.getAttribute("phx-hook") === "AdminTable") return;
  region.scrollTop = 0;
  region.scrollIntoView({block: "start"});
}

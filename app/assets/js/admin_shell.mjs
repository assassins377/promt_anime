// Presentation only: the drawer never fetches data or changes permissions.
export function adminShell() {
  return {
    opened: false,
    previousOverflow: "",
    init() {
      this.desktop = matchMedia("(min-width: 1280px)");
      this.onResize = () => { if (this.desktop.matches) this.close(); };
      this.onNavigate = () => this.close(false);
      this.desktop.addEventListener("change", this.onResize);
      window.addEventListener("phx:page-loading-start", this.onNavigate);
    },
    open() {
      if (this.opened || this.desktop.matches) return;
      this.previousOverflow = document.body.style.overflow;
      this.$refs.drawer.showModal();
      this.opened = true;
      document.body.style.overflow = "hidden";
    },
    close(restoreFocus = true) {
      if (!this.opened) return;
      this.$refs.drawer.close();
      this.opened = false;
      document.body.style.overflow = this.previousOverflow;
      if (restoreFocus) {
        const target = this.desktop.matches ? this.$refs.content : this.$refs.menuButton;
        target?.focus({preventScroll: true});
      }
    },
    destroy() {
      this.close(false);
      this.desktop.removeEventListener("change", this.onResize);
      window.removeEventListener("phx:page-loading-start", this.onNavigate);
    }
  };
}

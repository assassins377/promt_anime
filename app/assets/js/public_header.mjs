// Alpine owns presentation only; locale and logout use ordinary CSRF-protected forms.
export function publicDropdown() {
  return {
    opened: false,
    init() {
      this.onNavigate = () => this.close(false);
      window.addEventListener("phx:page-loading-start", this.onNavigate);
    },
    controls() {
      return [...this.$refs.panel.querySelectorAll("a[href], button:not([disabled]), input:not([type=hidden]), select, [tabindex]")]
        .filter(node => node.tabIndex >= 0 && node.getClientRects().length > 0);
    },
    toggle() {
      if (this.opened) return this.close();
      this.opened = true;
      this.$nextTick(() => { if (this.opened) this.controls()[0]?.focus(); });
    },
    close(restoreFocus = true) {
      if (!this.opened) return;
      this.opened = false;
      if (restoreFocus) this.$refs.trigger.focus();
    },
    keydown(event) {
      if (!this.opened) return;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        this.close();
      } else if (event.key === "Tab") {
        const controls = this.controls();
        const first = controls[0];
        const last = controls.at(-1);
        if (!first) { event.preventDefault(); return this.$refs.trigger.focus(); }
        if (event.shiftKey && (document.activeElement === first || !controls.includes(document.activeElement))) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && (document.activeElement === last || !controls.includes(document.activeElement))) {
          event.preventDefault(); first.focus();
        }
      }
    },
    destroy() { window.removeEventListener("phx:page-loading-start", this.onNavigate); }
  };
}

export function siteHeader() {
  return {
    tabsHidden: false,
    init() {
      this.lastY = window.scrollY;
      this.onScroll = () => {
        const y = Math.max(0, window.scrollY);
        if (Math.abs(y - this.lastY) < 8 && y > 72) return;
        this.tabsHidden = y > 72 && y > this.lastY && !this.$el.contains(document.activeElement);
        this.lastY = y;
      };
      this.sync = () => {
        this.tabsHidden = false;
        this.$nextTick(() => this.revealActive());
      };
      window.addEventListener("scroll", this.onScroll, {passive: true});
      window.addEventListener("resize", this.sync);
      window.addEventListener("phx:page-loading-stop", this.sync);
      this.sync();
      document.fonts?.ready.then(() => this.revealActive());
    },
    revealActive() {
      const nav = this.$refs.types;
      const active = nav.querySelector('[aria-current="page"]');
      if (!active) return;
      const item = active.getBoundingClientRect();
      const container = nav.getBoundingClientRect();
      if (item.left < container.left || item.right > container.right)
        nav.scrollLeft += item.left - container.left - (container.width - item.width) / 2;
    },
    destroy() {
      window.removeEventListener("scroll", this.onScroll);
      window.removeEventListener("resize", this.sync);
      window.removeEventListener("phx:page-loading-stop", this.sync);
    }
  };
}

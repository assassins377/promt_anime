import test from "node:test";
import assert from "node:assert/strict";
import {publicDropdown, siteHeader} from "../../assets/js/public_header.mjs";

function environment() {
  const listeners = new Map();
  globalThis.window = {scrollY: 0,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name, fn) => { if (listeners.get(name) === fn) listeners.delete(name); }
  };
  globalThis.document = {activeElement: null};
  return listeners;
}
function control(visible = true) {
  const node = {tabIndex: 0, getClientRects: () => visible ? [{}] : [], focus() { document.activeElement = node; }};
  return node;
}
function fixture() {
  const listeners = environment();
  const first = control(), hidden = control(false), last = control(), trigger = control();
  const data = Object.assign(publicDropdown(), {
    $refs: {trigger, panel: {querySelectorAll: () => [first, hidden, last]}},
    $nextTick: fn => fn()
  });
  data.init();
  return {data, first, last, trigger, listeners};
}
function key(key, shiftKey = false) {
  return {key, shiftKey, prevented: false, stopped: false,
    preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }};
}
test("dropdown focuses first visible control, traps tab both ways, returns on Escape", () => {
  const {data, first, last, trigger} = fixture();
  data.toggle(); assert.equal(data.opened, true); assert.equal(document.activeElement, first);
  const backward = key("Tab", true); data.keydown(backward);
  assert.equal(backward.prevented, true); assert.equal(document.activeElement, last);
  const forward = key("Tab"); data.keydown(forward);
  assert.equal(forward.prevented, true); assert.equal(document.activeElement, first);
  const escape = key("Escape"); data.keydown(escape);
  assert.equal(escape.stopped, true); assert.equal(data.opened, false); assert.equal(document.activeElement, trigger);
});
test("outside click and navigation close without stealing focus; listeners are removed", () => {
  const {data, listeners} = fixture();
  data.toggle(); const elsewhere = control(); elsewhere.focus();
  data.close(false); assert.equal(document.activeElement, elsewhere);
  data.toggle(); listeners.get("phx:page-loading-start")(); assert.equal(data.opened, false);
  data.destroy(); assert.equal(listeners.size, 0);
});
test("normal tab inside menu is not blocked and toggle closes", () => {
  const {data, trigger} = fixture(); data.toggle();
  const tab = key("Tab"); data.keydown(tab); assert.equal(tab.prevented, false);
  data.toggle(); assert.equal(document.activeElement, trigger); assert.equal(data.opened, false);
});
test("header hides only types on downward scroll, restores on up or keyboard focus", () => {
  const listeners = environment(); let focused = false;
  const nav = {scrollLeft: 0, querySelector: () => null};
  const data = Object.assign(siteHeader(), {$refs: {types: nav}, $el: {contains: () => focused}, $nextTick: fn => fn()});
  data.init(); window.scrollY = 200; listeners.get("scroll")(); assert.equal(data.tabsHidden, true);
  window.scrollY = 100; listeners.get("scroll")(); assert.equal(data.tabsHidden, false);
  focused = true; window.scrollY = 300; listeners.get("scroll")(); assert.equal(data.tabsHidden, false);
  data.destroy(); assert.equal(listeners.size, 0);
});
test("active type is centered within nav without scrolling the page", () => {
  environment();
  const nav = {scrollLeft: 0, getBoundingClientRect: () => ({left:0, right:320, width:320}),
    querySelector: () => ({getBoundingClientRect: () => ({left:350, right:410, width:60})})};
  const data = Object.assign(siteHeader(), {$refs: {types: nav}});
  data.revealActive(); assert.equal(nav.scrollLeft, 220); assert.equal(window.scrollY, 0);
});

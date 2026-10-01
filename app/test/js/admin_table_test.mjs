import test from "node:test";
import assert from "node:assert/strict";
import {AdminTable, scrollPatchedAdminTable} from "../../assets/js/admin_table.mjs";

function fixture() {
  globalThis.document = {activeElement: null};
  const state = {busy:false, height:540, scrolled:0};
  const hook = {...AdminTable, el: {
    style: {removeProperty() {delete this.minHeight;}}, scrollTop:100,
    getBoundingClientRect: () => ({height:state.height}),
    getAttribute: () => String(state.busy),
    scrollIntoView: () => {state.scrolled++;}
  }};
  hook.mounted();
  return {hook, state};
}

test("holds original height through replacement/cancellation and releases it at completion", () => {
  const {hook, state} = fixture();
  hook.beforeUpdate(); state.busy=true; state.height=320; hook.updated();
  assert.equal(hook.el.style.minHeight, "min(540px, 65vh)");
  hook.beforeUpdate(); state.height=100; hook.updated();
  assert.equal(hook.el.style.minHeight, "min(540px, 65vh)");
  state.busy=false; hook.updated();
  assert.equal(hook.el.style.minHeight, undefined);
  assert.equal(hook.el.scrollTop, 0);
  assert.equal(state.scrolled, 1);
});

test("captures resized table before the next request and does not scroll on unrelated patches", () => {
  const {hook, state} = fixture();
  hook.updated(); assert.equal(state.scrolled, 0);
  state.height=280; hook.beforeUpdate(); state.busy=true; hook.updated();
  assert.equal(hook.el.style.minHeight, "min(280px, 65vh)");
});

test("filter updates reset table rows without scrolling the focused filter out of view", () => {
  const {hook, state} = fixture();
  document.activeElement = {closest: selector => selector === ".admin-filters" ? {} : null};
  hook.beforeUpdate(); state.busy = true; hook.updated();
  state.busy = false; hook.updated();
  assert.equal(hook.el.scrollTop, 0);
  assert.equal(state.scrolled, 0);
});

test("patch event leaves async tables to their completion hook", () => {
  const {hook, state} = fixture();
  const doc = {activeElement: null, querySelector: () => ({...hook.el, getAttribute: () => "AdminTable"})};
  scrollPatchedAdminTable({detail: {kind: "patch"}}, doc);
  assert.equal(state.scrolled, 0);
});

test("synchronous nested pagination scrolls once, except while editing filters", () => {
  const {hook, state} = fixture();
  const doc = {activeElement: null, querySelector: () => hook.el};
  scrollPatchedAdminTable({detail: {kind: "redirect"}}, doc);
  assert.equal(state.scrolled, 0);
  scrollPatchedAdminTable({detail: {kind: "patch"}}, doc);
  assert.equal(state.scrolled, 1);
  assert.equal(hook.el.scrollTop, 0);
  doc.activeElement = {closest: () => ({})};
  scrollPatchedAdminTable({detail: {kind: "patch"}}, doc);
  assert.equal(state.scrolled, 1);
});

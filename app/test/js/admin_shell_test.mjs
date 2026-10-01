import test from "node:test";
import assert from "node:assert/strict";
import {adminShell} from "../../assets/js/admin_shell.mjs";

function fixture() {
  const events = new Map(), mediaEvents = new Map();
  const media = {matches: false,
    addEventListener: (event, fn) => mediaEvents.set(event, fn),
    removeEventListener: (event, fn) => { if (mediaEvents.get(event) === fn) mediaEvents.delete(event); }};
  globalThis.matchMedia = () => media;
  globalThis.window = {addEventListener: (event, fn) => events.set(event, fn),
    removeEventListener: (event, fn) => { if (events.get(event) === fn) events.delete(event); }};
  globalThis.document = {body: {style: {overflow: "auto"}}};
  const state = {shows: 0, closes: 0, focused: null};
  const data = Object.assign(adminShell(), {$refs: {
    drawer: {showModal() { state.shows++; }, close() { state.closes++; }},
    menuButton: {focus() { state.focused = "trigger"; }},
    content: {focus() { state.focused = "content"; }}
  }});
  data.init();
  return {data, state, media, events, mediaEvents};
}

test("opening twice does not overwrite the original body overflow", () => {
  const {data, state} = fixture();
  data.open(); data.open();
  assert.equal(state.shows, 1);
  assert.equal(document.body.style.overflow, "hidden");
  data.close(); data.close();
  assert.equal(state.closes, 1);
  assert.equal(document.body.style.overflow, "auto");
  assert.equal(state.focused, "trigger");
});

test("desktop breakpoint closes modal, unlocks body and focuses visible content", () => {
  const {data, state, media, mediaEvents} = fixture();
  data.open(); media.matches = true; mediaEvents.get("change")();
  assert.equal(data.opened, false);
  assert.equal(document.body.style.overflow, "auto");
  assert.equal(state.focused, "content");
  data.open(); assert.equal(state.shows, 1);
});

test("navigation and destroy release scroll lock and remove all listeners", () => {
  const {data, state, events, mediaEvents} = fixture();
  data.open(); events.get("phx:page-loading-start")();
  assert.equal(data.opened, false);
  assert.equal(state.focused, null);
  data.open(); data.destroy();
  assert.equal(document.body.style.overflow, "auto");
  assert.equal(events.size, 0); assert.equal(mediaEvents.size, 0);
});

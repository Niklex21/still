import { strict as assert } from "node:assert";
import { test } from "node:test";
import { captureDate, imagePath, libraryRoot, matches, passesFilter } from "../src/library.ts";
import type { Capture } from "../src/library.ts";

const item: Capture = { id: "abc", title: "Café design", text: "Release checklist", filename: "abc.png", createdAt: 0, width: 300, height: 200, onShelf: true, favorite: false, revision: 0 };
test("search matches title and OCR with accents, multiple words, and case", () => {
  assert.equal(matches(item, "CAFE checklist"), true);
  assert.equal(matches(item, "  release    design  "), true);
  assert.equal(matches(item, "invoice design"), false);
  assert.equal(matches(item, ""), true);
});
test("Swift reference date converts to a JavaScript date", () => {
  assert.equal(captureDate(item).toISOString(), "2001-01-01T00:00:00.000Z");
});
test("visual search combines descriptions, tags, title, and OCR, and rejects stale metadata", () => {
  const visual = { ...item, visualIndex: { version: 1, revision: 0, summary: "A blue bar chart", keywords: ["graph", "dashboard"] } };
  assert.equal(matches(visual, "CAFE blue checklist"), true);
  assert.equal(matches(visual, "graph dashboard"), true);
  assert.equal(matches(visual, "red chart"), false);
  assert.equal(matches({ ...visual, revision: 1 }, "blue chart"), false);
  assert.equal(matches({ ...visual, visualIndex: { ...visual.visualIndex, version: 2 } }, "blue chart"), false);
});
test("image paths stay inside Images even for a malformed index entry", () => {
  assert.equal(imagePath({ ...item, filename: "../../secret.png" }), `${libraryRoot}/Images/secret.png`);
});

test("metadata search and source/date filters", () => {
  const capture = { ...item, metadata: { application: "Safari", kind: "Window", notes: "Billing flow", tags: ["payments"], sourceURL: "https://example.com/checkout" } };
  assert.equal(matches(capture, "safari billing payments checkout"), true);
  assert.equal(passesFilter(capture, "app:Safari"), true);
  assert.equal(passesFilter(capture, "app:Finder"), false);
  assert.equal(passesFilter(capture, "text"), true);
  assert.equal(passesFilter(capture, "week", new Date("2001-01-03")), true);
  assert.equal(passesFilter(capture, "today", new Date("2001-01-03")), false);
});

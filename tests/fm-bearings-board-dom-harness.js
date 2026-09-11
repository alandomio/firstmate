// fm-bearings-board-dom-harness.js - a minimal, hand-rolled DOM shim that runs
// the REAL board-template.html runtime script (extracted verbatim by the
// caller, unmodified) inside a Node vm context, so
// tests/fm-bearings-board.test.sh can exercise the template's client-side
// answer-queueing behavior without asserting against its source bytes and
// without adding a browser or jsdom dependency to this bash-only test suite.
//
// It implements only the element surface the script actually touches
// (className/classList, textContent, appendChild/children/parentNode,
// addEventListener/dispatch, and the handful of getElementById targets the
// static page skeleton provides), plus a tiny FormData polyfill backed by
// that shim, since Node's own global FormData does not support the browser's
// `new FormData(formElement)` reflection.
//
// Usage: node fm-bearings-board-dom-harness.js <script-file> <payload-file> <bridge:0|1> <mode:decision|dispatch>
// Prints one JSON line: {"isQueued":bool,"errorVisible":bool,"errorText":str,"queueCalls":n}
// where errorVisible/errorText report the state of the alert element each mode
// actually uses - the card's .bb-limit for decision mode, and the dispatch
// bar's own count label (an error there replaces the picked-count text) for
// dispatch mode.

"use strict";
const fs = require("fs");
const vm = require("vm");

const [scriptFile, payloadFile, bridgeFlag, mode] = process.argv.slice(2);
const scriptSrc = fs.readFileSync(scriptFile, "utf8");
const payloadJson = fs.readFileSync(payloadFile, "utf8");

class FakeNode {
  constructor(tag) {
    this.tagName = String(tag || "").toUpperCase();
    this._className = "";
    this._textContent = "";
    this.innerHTML = "";
    this.children = [];
    this.parentNode = null;
    this.attributes = {};
    this.listeners = {};
    this.hidden = false;
    this.disabled = false;
    this.type = "";
    this.name = "";
    this.value = "";
    this.checked = false;
    this.placeholder = "";
    const node = this;
    this.classList = {
      set: new Set(),
      add(c) { this.set.add(c); node._syncClassName(); },
      remove(c) { this.set.delete(c); node._syncClassName(); },
      contains(c) { return this.set.has(c); },
      toggle(c, force) {
        if (force === undefined) { this.set.has(c) ? this.set.delete(c) : this.set.add(c); }
        else if (force) { this.set.add(c); } else { this.set.delete(c); }
        node._syncClassName();
      },
    };
  }
  _syncClassName() { this._className = Array.from(this.classList.set).join(" "); }
  get className() { return this._className; }
  set className(v) {
    this._className = v || "";
    this.classList.set = new Set(String(v || "").split(/\s+/).filter(Boolean));
  }
  get textContent() { return this._textContent; }
  set textContent(v) { this._textContent = v; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  dispatch(type, evt) { (this.listeners[type] || []).forEach((fn) => fn(evt)); }
  querySelectorAll(sel) {
    const cls = sel.replace(/^\./, "").split(":")[0];
    const wantChecked = sel.includes(":checked");
    const out = [];
    const walk = (n) => {
      (n.children || []).forEach((c) => {
        if (c.classList.contains(cls) && (!wantChecked || c.checked)) out.push(c);
        walk(c);
      });
    };
    walk(this);
    return out;
  }
}

function findAll(root, pred, out) {
  out = out || [];
  (root.children || []).forEach((c) => {
    if (pred(c)) out.push(c);
    findAll(c, pred, out);
  });
  return out;
}

const registry = {};
["bb-provenance", "bb-stats", "bb-call-sub", "bb-call", "bb-stack-count", "bb-stack-prev",
  "bb-stack-next", "bb-underway", "bb-landed", "bb-charted", "bb-charted-sub", "bb-dispatch",
  "bb-dispatch-count", "bb-dispatch-btn"].forEach((id) => { registry[id] = new FakeNode("div"); });
// stackNav = stackCount.parentNode in the real script - give it a wrapper so
// that property resolves the same way it would in the shipped page.
const stackNav = new FakeNode("div");
stackNav.appendChild(registry["bb-stack-count"]);

const bearingsData = new FakeNode("script");
bearingsData.textContent = payloadJson;
registry["bearings-data"] = bearingsData;

const bbMain = new FakeNode("div");

const fakeDocument = {
  getElementById(id) { return registry[id] || null; },
  querySelector(sel) { return sel === ".bb-main" ? bbMain : null; },
  createElement(tag) { return new FakeNode(tag); },
};

function FormDataShim(form) { this._form = form; }
FormDataShim.prototype.get = function (name) {
  const inputs = findAll(this._form, (n) => n.name === name);
  for (const input of inputs) {
    if (input.type === "radio" || input.type === "checkbox") {
      if (input.checked) return input.value;
    } else {
      return input.value;
    }
  }
  return null;
};

const queueCalls = [];
const fakeWindow = {};
if (bridgeFlag === "1") {
  fakeWindow.lavish = { queuePrompt: function () { queueCalls.push(Array.prototype.slice.call(arguments)); } };
}

const sandbox = {
  document: fakeDocument,
  window: fakeWindow,
  FormData: FormDataShim,
  TextEncoder,
  setTimeout: () => {},
  console,
};
vm.createContext(sandbox);
vm.runInContext(scriptSrc, sandbox, { filename: "board-template-runtime.js" });

let result;
if (mode === "decision") {
  const deck = registry["bb-call"];
  const card = deck.children[0];
  const form = findAll(card, (n) => n.tagName === "FORM")[0];
  const radio = findAll(form, (n) => n.tagName === "INPUT" && n.type === "radio")[0];
  radio.checked = true;
  form.dispatch("submit", { preventDefault() {} });
  const answerLimit = findAll(card, (n) => n.classList.contains("bb-limit"))[0];
  result = {
    isQueued: card.classList.contains("is-queued"),
    errorVisible: answerLimit.classList.contains("is-visible"),
    errorText: answerLimit.textContent,
    queueCalls: queueCalls.length,
  };
} else if (mode === "dispatch") {
  const bar = registry["bb-dispatch"];
  const barCount = registry["bb-dispatch-count"];
  const ch = registry["bb-charted"];
  const pick = findAll(ch, (n) => n.classList.contains("bb-pick"))[0];
  pick.checked = true;
  pick.dispatch("change");
  const barBtn = registry["bb-dispatch-btn"];
  const labelBeforeClick = barCount.textContent;
  barBtn.dispatch("click");
  result = {
    isQueued: bar.classList.contains("is-queued"),
    errorVisible: barCount.textContent !== labelBeforeClick,
    errorText: barCount.textContent,
    queueCalls: queueCalls.length,
  };
} else {
  throw new Error("unknown mode: " + mode);
}

process.stdout.write(JSON.stringify(result) + "\n");

// Behavior tests for the preview-local runtime. Native sandbox coverage lives
// in browser-fixture/html_preview.rs; this VM is not a WebKit security test.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../src/browser/visualize-controls.js', import.meta.url), 'utf8');
const carouselSource = readFileSync(new URL('../src/browser/visualize.js', import.meta.url), 'utf8');
class Target {
  listeners = new Map();
  addEventListener(name, callback) { const list = this.listeners.get(name) ?? []; list.push(callback); this.listeners.set(name, list); }
  removeEventListener(name, callback) { this.listeners.set(name, (this.listeners.get(name) ?? []).filter(x => x !== callback)); }
  dispatchEvent(event) { for (const listener of this.listeners.get(event.type) ?? []) listener(event); }
}
class Element extends Target {
  children = []; style = {}; dataset = {}; selectedIndex = -1;
  append(...children) { children.forEach(child => { child.parent = this; this.children.push(child); }); }
  attachShadow() { return this.shadowRoot = new Element(); }
  setAttribute(key, value) { this[key] = value; }
  getAttribute(key) { return this[key]; }
  remove() { this.parent.children = this.parent.children.filter(child => child !== this); }
  matches(selector) { return selector === 'section[data-variant]' && this.dataset.variant !== undefined; }
}
function runtime() {
  const window = new Target();
  const document = new Target();
  document.body = new Element(); document.createElement = () => new Element();
  document.querySelectorAll = () => [];
  const context = vm.createContext({ window, document, TextEncoder, queueMicrotask,
    CustomEvent: class { constructor(type, { detail }) { Object.assign(this, { type, detail }); } } });
  vm.runInContext(source, context);
  return { context, window, document, api: window.openai, Tweak: vm.runInContext('Tweak', context) };
}
const plain = value => JSON.parse(JSON.stringify(value));

test('state is copied on input/read/event, local to one page, and not a host SDK', async () => {
  const { api, window } = runtime();
  const events = [];
  window.addEventListener('openai:set_globals', event => events.push(event.detail.globals.widgetState));
  const input = { nested: { answer: 'yes' } };
  const update = api.setWidgetState(input); input.nested.answer = 'mutated'; await update;
  assert.deepEqual(plain(api.widgetState), { nested: { answer: 'yes' } });
  const output = api.widgetState; output.nested.answer = 'read mutation'; events[0].nested.answer = 'event mutation';
  assert.equal(api.widgetState.nested.answer, 'yes');
  assert.deepEqual(Object.keys(api).sort(), ['setWidgetState', 'widgetState']);
  for (const key of ['callTool', 'sendFollowUpMessage', 'openExternal', 'requestDisplayMode']) assert.equal(api[key], undefined);
  assert.deepEqual(plain(runtime().api.widgetState), {}, 'a reload/new page must not share state');
  assert.equal(Object.isFrozen(api), true);
});

test('UTF-8 JSON bound is exactly 64 KiB and invalid updates are atomic', async () => {
  const { api, window } = runtime(); let events = 0;
  window.addEventListener('openai:set_globals', () => events++);
  const limit = { x: 'é'.repeat(32764) }; // 8 JSON punctuation bytes + 65528 UTF-8 bytes.
  assert.equal(new TextEncoder().encode(JSON.stringify(limit)).length, 65536);
  await api.setWidgetState(limit);
  const cyclic = {}; cyclic.self = cyclic;
  for (const value of [null, [], 'text', 1, cyclic, { x: 1n }, { x: limit.x + 'é' }, { toJSON: () => [] }]) {
    await assert.rejects(api.setWidgetState(value));
    assert.equal(api.widgetState.x, limit.x);
  }
  assert.equal(events, 1);
});

test('concurrent update events retain each committed snapshot', async () => {
  const { api, window } = runtime(); const states = [];
  window.addEventListener('openai:set_globals', e => states.push(e.detail.globals.widgetState.n));
  await Promise.all([api.setWidgetState({ n: 1 }), api.setWidgetState({ n: 2 })]);
  assert.deepEqual(states, [1, 2]); assert.equal(api.widgetState.n, 2);
});

test('select/toggle bindings use scoped native controls and refresh after all global listeners', async () => {
  const { api, window, document, Tweak } = runtime();
  const container = new Element(), other = new Element(), bound = { answer: 'a', translation: false };
  const changes = [];
  const controls = new Tweak({ container, onChange: (object, key) => changes.push([object[key], key]) });
  const second = new Tweak({ container: other });
  const select = controls.addSelect(bound, 'answer', { options: { First: 'a', Second: 'b' } });
  const toggle = controls.addToggle(bound, 'translation');
  assert.equal(container.children.length, 1); assert.equal(document.body.children.length, 0);
  assert.ok(controls.host.shadowRoot); assert.notEqual(controls.host.shadowRoot, second.host.shadowRoot);
  select.selectedIndex = 1; select.dispatchEvent({ type: 'change' });
  toggle.checked = true; toggle.dispatchEvent({ type: 'change' });
  assert.deepEqual(changes, [['b', 'answer'], [true, 'translation']]);
  window.addEventListener('openai:set_globals', event => Object.assign(bound, event.detail.globals.widgetState));
  await api.setWidgetState({ answer: 'a', translation: false }); await Promise.resolve();
  assert.equal(select.selectedIndex, 0); assert.equal(toggle.checked, false);
  const array = controls.addSelect(bound, 'answer', { options: ['a', 'b'] });
  array.selectedIndex = -1; array.dispatchEvent({ type: 'change' }); assert.equal(bound.answer, 'a');
  controls.dispose(); assert.equal(container.children.length, 0);
  assert.equal(window.listeners.get('openai:set_globals').length, 2, 'only second panel and app listener remain');
});

test('carousel navigation is scoped to direct variant children', () => {
  const { context, document } = runtime();
  const one = new Element(), two = new Element();
  const slide = (variant, hidden) => Object.assign(new Element(), { dataset: { variant }, hidden });
  const first = slide('One', false), second = slide('Two', true), third = slide('Other', false), fourth = slide('Last', true);
  one.append(first, second, new Element()); two.append(third, fourth);
  document.querySelectorAll = selector => { assert.equal(selector, '.viz-carousel'); return [one, two]; };
  vm.runInContext(carouselSource, context); document.dispatchEvent({ type: 'DOMContentLoaded' });
  const [previous, status, next] = one.children.at(-1).children;
  assert.equal(previous.disabled, true); assert.equal(status.textContent, '1 / 2 · One');
  next.dispatchEvent({ type: 'click' }); assert.equal(first.hidden, true); assert.equal(second.hidden, false);
  assert.equal(next.disabled, true); assert.equal(third.hidden, false); assert.equal(fourth.hidden, true);
  previous.dispatchEvent({ type: 'click' }); assert.equal(first.hidden, false);
});

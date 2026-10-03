import assert from "node:assert/strict"
import {test} from "node:test"
import WorkspaceSearch from "./workspace_switcher.js"

function mountSearch(t) {
  const root = new EventTarget()
  const option = {}
  const outside = {}
  const el = {isConnected: true, closest: () => root, focus() {}}
  const events = []
  const previousDocument = globalThis.document

  globalThis.document = {activeElement: outside}
  root.contains = node => node === el || node === option

  const hook = {
    ...WorkspaceSearch,
    el,
    pushEventTo(_target, event) { events.push(event) },
  }

  hook.mounted()
  t.after(() => {
    hook.destroyed()
    if (previousDocument === undefined) delete globalThis.document
    else globalThis.document = previousDocument
  })

  const focusOut = async relatedTarget => {
    globalThis.document.activeElement = relatedTarget || outside
    const event = new Event("focusout")
    Object.defineProperty(event, "relatedTarget", {value: relatedTarget})
    root.dispatchEvent(event)
    await Promise.resolve()
  }

  return {events, option, outside, focusOut}
}

test("a pointer blur with no new focus keeps workspace links available for the click", async t => {
  const {events, focusOut} = mountSearch(t)
  await focusOut(null)
  assert.deepEqual(events, [])
})

test("moving focus to a workspace option keeps the menu open", async t => {
  const {events, option, focusOut} = mountSearch(t)
  await focusOut(option)
  assert.deepEqual(events, [])
})

test("tabbing to an element outside the switcher closes the menu", async t => {
  const {events, outside, focusOut} = mountSearch(t)
  await focusOut(outside)
  assert.deepEqual(events, ["close"])
})

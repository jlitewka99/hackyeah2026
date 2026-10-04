import test from "node:test"
import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"

const source = await readFile(new URL("./copy_text.js", import.meta.url), "utf8")
const {CopyText} = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)

test("copies only the endpoint, restores the button and detaches its listener", async () => {
  let copied
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {clipboard: {
    writeText: async value => { copied = value },
  }}})
  const input = {value: "https://gateway.example/" + "deployment/".repeat(40) + "mcp"}
  const status = {textContent: ""}
  let listener
  const button = {disabled: false,
    addEventListener: (_, callback) => { listener = callback },
    removeEventListener: (_, callback) => { assert.equal(callback, listener); listener = null },
  }
  const hook = {el: {querySelector: selector => ({
    "[data-copy-value]": input, "[data-copy-text]": button, "[data-copy-status]": status,
  })[selector]}}
  CopyText.mounted.call(hook)
  await listener()
  assert.equal(copied, input.value)
  assert.equal(status.textContent, "Endpoint copied.")
  assert.equal(button.disabled, false)
  CopyText.destroyed.call(hook)
  assert.equal(listener, null)
})

test("clipboard denial or absence selects the endpoint for manual copying", async () => {
  for (const clipboard of [undefined, {writeText: async () => { throw new Error("denied") }}]) {
    Object.defineProperty(globalThis, "navigator", {configurable: true, value: {clipboard}})
    const calls = []
    const input = {value: "http://localhost:4000/mcp", focus: () => calls.push("focus"), select: () => calls.push("select")}
    const button = {addEventListener() {}, disabled: false}
    const status = {}
    const hook = {el: {querySelector: selector => ({
      "[data-copy-value]": input, "[data-copy-text]": button, "[data-copy-status]": status,
    })[selector]}}
    CopyText.mounted.call(hook)
    await hook.copy()
    assert.deepEqual(calls, ["focus", "select"])
    assert.match(status.textContent, /Ctrl\+C or Command\+C/)
    assert.equal(button.disabled, false)
  }
})

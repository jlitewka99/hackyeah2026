// Standard Streamable HTTP smoke client. No extra idempotency header is sent.
import assert from "node:assert/strict"

const endpoint = process.env.MCP_URL || "http://localhost:4000/mcp"
const token = process.env.MCP_API_KEY
if (!token) throw new Error("Set MCP_API_KEY to an active agent key.")
let session
let nextId = 0
const headers = () => ({
  "Authorization": `Bearer ${token}`,
  "Content-Type": "application/json",
  "Accept": "application/json, text/event-stream",
  "MCP-Protocol-Version": "2025-11-25",
  ...(session ? {"MCP-Session-Id": session} : {}),
})
const rpc = async (method, params = {}) => {
  const id = nextId++
  const response = await fetch(endpoint, {method: "POST", headers: headers(),
    body: JSON.stringify({jsonrpc: "2.0", id, method, params})})
  assert.equal(response.status, 200, `HTTP failure for ${method}`)
  const body = await response.json()
  assert.equal(body.id, id)
  assert.equal(body.jsonrpc, "2.0")
  assert.equal(body.error, undefined, `Protocol failure for ${method}`)
  session ||= response.headers.get("mcp-session-id")
  return body.result
}

try {
  const initialized = await rpc("initialize", {protocolVersion: "2025-11-25", capabilities: {},
    clientInfo: {name: "ai-control-smoke", version: "1.0.0"}})
  assert.equal(initialized.protocolVersion, "2025-11-25")
  assert.ok(session)
  const ready = await fetch(endpoint, {method: "POST", headers: headers(),
    body: JSON.stringify({jsonrpc: "2.0", method: "notifications/initialized"})})
  assert.equal(ready.status, 202)
  assert.equal(await ready.text(), "")
  assert.deepEqual(await rpc("ping"), {})
  const tools = await rpc("tools/list")
  assert.ok(tools.tools.some(tool => tool.name === "file.read"), "Grant file.read before this smoke test.")
  const resources = await rpc("resources/list")
  const resource = resources.resources[0]
  assert.ok(resource, "Configure an authorized synthetic sandbox file before this smoke test.")
  const tool = await rpc("tools/call", {name: "file.read", arguments: {path: resource.name}})
  assert.equal(tool.isError, false)
  assert.deepEqual(JSON.parse(tool.content[0].text), tool.structuredContent)
  const read = await rpc("resources/read", {uri: resource.uri})
  assert.equal(read.contents[0].text, tool.structuredContent.content)
  const denied = await rpc("tools/call", {name: "file.read", arguments: {path: "~/.ssh/id_rsa"}})
  assert.equal(denied.isError, true)
  assert.equal(denied.structuredContent, undefined)
  console.log("MCP smoke passed: initialize, ready, ping, discovery, tool call, resource read and ACL denial.")
} finally {
  if (session) {
    const deleted = await fetch(endpoint, {method: "DELETE", headers: headers()})
    assert.equal(deleted.status, 204)
  }
}

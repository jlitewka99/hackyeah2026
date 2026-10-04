// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ai_control"
import topbar from "../vendor/topbar"
import WorkspaceSearch from "./workspace_switcher"
import {OneTimeSecret} from "./one_time_secret"
import {CopyText} from "./copy_text"

// Appearance belongs to the application bundle, including cross-tab updates.
const systemAppearance = window.matchMedia("(prefers-color-scheme: dark)")
let appearance = "system"
try { appearance = localStorage.getItem("phx:theme") || "system" } catch (_) {}

const setAppearance = (value, persist = false) => {
  appearance = ["system", "light", "dark"].includes(value) ? value : "system"
  const resolved = appearance === "system" ? (systemAppearance.matches ? "dark" : "light") : appearance
  document.documentElement.dataset.theme = resolved
  document.documentElement.dataset.themeSource = appearance
  document.querySelectorAll("[data-phx-theme]").forEach(button => {
    button.setAttribute("aria-pressed", String(button.dataset.phxTheme === appearance))
  })
  if (persist) {
    try {
      if (appearance === "system") localStorage.removeItem("phx:theme")
      else localStorage.setItem("phx:theme", appearance)
    } catch (_) {}
  }
}
setAppearance(appearance)
window.addEventListener("phx:set-theme", event => setAppearance(event.target.closest("[data-phx-theme]").dataset.phxTheme, true))
window.addEventListener("storage", event => {
  if (event.key === "phx:theme") setAppearance(event.newValue || "system")
})
systemAppearance.addEventListener("change", () => {
  if (appearance === "system") setAppearance("system")
})
window.addEventListener("phx:page-loading-stop", () => setAppearance(appearance))

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, WorkspaceSearch, OneTimeSecret, CopyText},
})

window.addEventListener("keydown", event => {
  const trigger = event.target.closest("[data-workspace-trigger]")
  if (trigger && ["ArrowDown", "ArrowUp"].includes(event.key)) {
    event.preventDefault()
    liveSocket.execJS(trigger, trigger.dataset.open)
  }
})
window.addEventListener("phx:workspace-focus-trigger", event => {
  document.getElementById(event.detail.id)?.focus()
})

const workflowFocusTargets = {confirm: "run-stop-confirm", stop: "run-stop", status: "run-status"}
window.addEventListener("phx:workflow-focus", event => {
  const id = workflowFocusTargets[event.detail.target]
  if (id) document.getElementById(id)?.focus()
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#62646e"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Native POST forms keep credentials out of LiveView events. Give their
// submit buttons the same busy feedback as LiveView-managed forms.
const nativeSubmissions = new Map()
window.addEventListener("submit", event => {
  const form = event.target
  if (!(form instanceof HTMLFormElement) || form.hasAttribute("phx-submit")) return
  if (nativeSubmissions.has(form)) {
    event.preventDefault()
    return
  }
  const buttons = [...form.querySelectorAll("button[phx-disable-with]")]
  nativeSubmissions.set(form, buttons.map(button => ({button, html: button.innerHTML})))
  form.setAttribute("aria-busy", "true")
  buttons.forEach(button => {
    button.textContent = button.getAttribute("phx-disable-with")
    button.disabled = true
  })
  topbar.show(0)
})
window.addEventListener("pageshow", () => {
  nativeSubmissions.forEach((buttons, form) => {
    form.removeAttribute("aria-busy")
    buttons.forEach(({button, html}) => {
      button.innerHTML = html
      button.disabled = false
    })
  })
  nativeSubmissions.clear()
  topbar.hide()
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

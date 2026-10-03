// The server never restores a revealed secret after navigation or a new mount.
// Clear the existing DOM as soon as a connection is lost, including a reconnect
// that resumes the same LiveView process.
export const OneTimeSecret = {
  mounted() {
    this.input = this.el.querySelector("#api-key-secret")
    this.copyButton = this.el.querySelector("[data-copy-secret]")
    this.status = this.el.querySelector("#copy-key-status")
    this.copy = async () => {
      const secret = this.input.value
      if (!secret) return
      this.copyButton.disabled = true
      try {
        await navigator.clipboard.writeText(secret)
        this.status.textContent = "Copied. Store it securely."
      } catch (_) {
        this.input.focus()
        this.input.select()
        this.status.textContent = "Press Ctrl+C or Command+C to copy the selected key."
      } finally {
        this.copyButton.disabled = false
      }
    }
    this.copyButton.addEventListener("click", this.copy)
  },
  disconnected() {
    this.clear()
  },
  reconnected() {
    this.clear()
    this.pushEvent("dismiss_secret", {})
  },
  destroyed() {
    this.copyButton.removeEventListener("click", this.copy)
    this.clear()
  },
  clear() {
    this.input.value = ""
    this.input.removeAttribute("value")
    this.el.hidden = true
  },
}

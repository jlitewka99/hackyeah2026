export const CopyText = {
  mounted() {
    this.input = this.el.querySelector("[data-copy-value]")
    this.button = this.el.querySelector("[data-copy-text]")
    this.status = this.el.querySelector("[data-copy-status]")
    this.copy = async () => {
      this.button.disabled = true
      try {
        await navigator.clipboard.writeText(this.input.value)
        this.status.textContent = "Endpoint copied."
      } catch (_) {
        this.input.focus()
        this.input.select()
        this.status.textContent = "Press Ctrl+C or Command+C to copy the selected endpoint."
      } finally {
        this.button.disabled = false
      }
    }
    this.button.addEventListener("click", this.copy)
  },
  destroyed() {
    this.button.removeEventListener("click", this.copy)
  },
}

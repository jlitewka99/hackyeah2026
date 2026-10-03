// The server owns the options and open state; this hook only manages focus.
const WorkspaceSearch = {
  mounted() {
    this.root = this.el.closest("[data-workspace-switcher]")
    this.el.focus()

    this.onKeyDown = event => {
      const options = [...this.root.querySelectorAll("[data-workspace-option]")]
      const index = options.indexOf(document.activeElement)

      if (event.key === "Escape") {
        event.preventDefault()
        event.stopPropagation()
        this.pushEventTo(this.root, "close", {return_focus: true})
      } else if (["ArrowDown", "ArrowUp"].includes(event.key)) {
        event.preventDefault()
        if (!options.length) return
        const next = event.key === "ArrowDown"
          ? (index + 1) % options.length
          : (index <= 0 ? options.length - 1 : index - 1)
        options[next].focus()
      } else if (event.key === "Enter" && event.target === this.el) {
        event.preventDefault()
        if (event.isComposing || this.selectionPending) return
        const query = this.el.value
        this.selectionPending = true

        // Flush the current query and wait for its stream patch before selecting.
        this.pushEventTo(this.root, "search", {workspace_search: {query}})
          .then(replies => {
            if (replies.some(reply => reply.status === "rejected")) return
            if (!this.el.isConnected || this.el.value !== query || document.activeElement !== this.el) return
            this.root.querySelector("[data-workspace-option]")?.click()
          })
          .finally(() => { this.selectionPending = false })
      }
    }

    this.onFocusOut = () => {
      queueMicrotask(() => {
        if (this.el.isConnected && !this.root.contains(document.activeElement)) {
          this.pushEventTo(this.root, "close", {})
        }
      })
    }

    this.root.addEventListener("keydown", this.onKeyDown)
    this.root.addEventListener("focusout", this.onFocusOut)
  },

  destroyed() {
    this.root.removeEventListener("keydown", this.onKeyDown)
    this.root.removeEventListener("focusout", this.onFocusOut)
  },
}

export default WorkspaceSearch

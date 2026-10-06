export const FloatingInspector = {
  mounted() {
    this.position = null
    this.move = (x, y) => {
      const parent = this.el.parentElement
      this.position = {
        x: Math.max(0, Math.min(x, parent.clientWidth - this.el.offsetWidth)),
        y: Math.max(0, Math.min(y, parent.clientHeight - this.el.offsetHeight))
      }
      Object.assign(this.el.style, {left: `${this.position.x}px`, top: `${this.position.y}px`, right: "auto"})
    }
    this.down = event => {
      const handle = event.target.closest("[data-window-handle]")
      if (!handle || event.target.closest("button") || event.button !== 0) return
      const bounds = this.el.getBoundingClientRect()
      const parent = this.el.parentElement.getBoundingClientRect()
      this.drag = {id: event.pointerId, x: event.clientX, y: event.clientY, left: bounds.left - parent.left, top: bounds.top - parent.top}
      handle.setPointerCapture(event.pointerId)
      event.preventDefault()
    }
    this.pointer = event => {
      if (!this.drag || event.pointerId !== this.drag.id) return
      this.move(this.drag.left + event.clientX - this.drag.x, this.drag.top + event.clientY - this.drag.y)
    }
    this.up = () => { this.drag = null }
    this.key = event => {
      if (!event.target.matches("[data-window-handle]")) return
      const delta = {ArrowLeft: [-20, 0], ArrowRight: [20, 0], ArrowUp: [0, -20], ArrowDown: [0, 20]}[event.key]
      if (!delta) return
      event.preventDefault()
      this.move(this.el.offsetLeft + delta[0], this.el.offsetTop + delta[1])
    }
    this.el.addEventListener("pointerdown", this.down)
    this.el.addEventListener("pointermove", this.pointer)
    this.el.addEventListener("pointerup", this.up)
    this.el.addEventListener("pointercancel", this.up)
    this.el.addEventListener("keydown", this.key)
    this.resize = new ResizeObserver(() => { if (this.position) this.move(this.position.x, this.position.y) })
    this.resize.observe(this.el.parentElement)
  },
  updated() { if (this.position) this.move(this.position.x, this.position.y) },
  destroyed() {
    this.resize.disconnect()
    this.el.removeEventListener("pointerdown", this.down)
    this.el.removeEventListener("pointermove", this.pointer)
    this.el.removeEventListener("pointerup", this.up)
    this.el.removeEventListener("pointercancel", this.up)
    this.el.removeEventListener("keydown", this.key)
  }
}

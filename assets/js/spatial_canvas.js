const symbols = {idea: '◇', task: '☑', issue: '⊙', pr: '⑂', agent: '✳', reference: '▤'}
const svgNS = 'http://www.w3.org/2000/svg'
const make = (tag, cls, text) => {
  const el = document.createElement(tag)
  if (cls) el.className = cls
  if (text !== undefined) el.textContent = text
  return el
}
export const SpatialCanvas = {
  mounted() {
    this.plane = this.el.querySelector('.graph-plane')
    this.view = {x: 0, y: 0, scale: 1}
    this.drag = null
    this.renderGraph()
    this.onDown = e => {
      if (e.button !== 0 || e.target.closest('.zoom-controls')) return
      const card = e.target.closest('.graph-node')
      this.drag = {id: card?.dataset.id, card, startX: e.clientX, startY: e.clientY,
        x: card ? Number(card.dataset.x) : this.view.x,
        y: card ? Number(card.dataset.y) : this.view.y, moved: false}
      this.el.setPointerCapture(e.pointerId)
      if (card) card.classList.add('dragging')
    }
    this.onMove = e => {
      if (!this.drag) return
      const d = this.drag, dx = e.clientX - d.startX, dy = e.clientY - d.startY
      if (Math.abs(dx) + Math.abs(dy) > 5) d.moved = true
      if (!d.moved) return
      if (d.card) {
        d.card.style.left = `${d.x + dx / this.view.scale}px`
        d.card.style.top = `${d.y + dy / this.view.scale}px`
        const n = this.graph.nodes.find(n => n.id === d.id)
        if (n) {n.x = d.x + dx / this.view.scale; n.y = d.y + dy / this.view.scale}
        this.drawEdges()
      } else {
        this.view.x = d.x + dx; this.view.y = d.y + dy; this.transform()
      }
    }
    this.onUp = () => {
      const d = this.drag
      if (!d) return
      this.drag = null
      d.card?.classList.remove('dragging')
      if (d.card && d.moved) {
        const node = this.graph.nodes.find(n => n.id === d.id)
        this.pushEvent('move', {id: d.id, x: node.x, y: node.y})
      } else if (d.id) this.pushEvent('select', {id: d.card.dataset.parent || d.id})
    }
    this.onWheel = e => {
      e.preventDefault()
      const rect = this.el.getBoundingClientRect()
      const x = e.clientX - rect.left, y = e.clientY - rect.top
      this.zoom(this.view.scale * (e.deltaY > 0 ? 0.92 : 1.08), x, y)
    }
    this.onClick = e => {
      const action = e.target.closest('[data-action]')?.dataset.action
      if (action === 'in') this.zoom(this.view.scale * 1.2)
      if (action === 'out') this.zoom(this.view.scale / 1.2)
      if (action === 'fit') this.fit()
    }
    this.onKey = e => {
      const card = e.target.closest('.graph-node')
      if (!card) return
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault(); this.pushEvent('select', {id: card.dataset.parent || card.dataset.id}); return
      }
      const delta = {ArrowLeft: [-20, 0], ArrowRight: [20, 0], ArrowUp: [0, -20], ArrowDown: [0, 20]}[e.key]
      if (delta) {
        e.preventDefault()
        this.pushEvent('move', {id: card.dataset.id, x: Number(card.dataset.x) + delta[0], y: Number(card.dataset.y) + delta[1]})
      }
    }
    this.el.addEventListener('pointerdown', this.onDown)
    this.el.addEventListener('pointermove', this.onMove)
    this.el.addEventListener('pointerup', this.onUp)
    this.el.addEventListener('pointercancel', this.onUp)
    this.el.addEventListener('wheel', this.onWheel, {passive: false})
    this.el.addEventListener('click', this.onClick)
    this.el.addEventListener('keydown', this.onKey)
    this.resize = new ResizeObserver(() => this.transform())
    this.resize.observe(this.el)
    this.fit()
  },
  updated() {if (!this.drag) {const before = this.graph.nodes.length; this.renderGraph(); if (this.graph.nodes.length > before) this.fit()}},
  destroyed() {
    this.resize.disconnect()
    for (const [name, fn] of [['pointerdown', this.onDown], ['pointermove', this.onMove], ['pointerup', this.onUp], ['pointercancel', this.onUp], ['wheel', this.onWheel], ['click', this.onClick], ['keydown', this.onKey]]) this.el.removeEventListener(name, fn)
  },
  renderGraph() {
    this.graph = JSON.parse(this.el.dataset.graph)
    this.plane.replaceChildren()
    this.svg = document.createElementNS(svgNS, 'svg')
    this.svg.classList.add('graph-edges')
    this.svg.setAttribute('viewBox', '-6000 -6000 12000 12000')
    this.plane.append(this.svg)
    for (const node of this.graph.nodes) {
      const card = make('button', `graph-node ${node.kind}${node.id === this.graph.selected ? ' selected' : ''}`)
      card.id = `node-${node.id}`; card.dataset.id = node.id; if(node.parent_id) card.dataset.parent = node.parent_id
      card.dataset.x = node.x; card.dataset.y = node.y
      card.style.left = `${node.x}px`; card.style.top = `${node.y}px`
      card.setAttribute('aria-label', `${node.kind}: ${node.title}. ${node.status}. Use arrow keys to move.`)
      const header = make('div', 'node-header')
      header.append(make('span', 'node-symbol', symbols[node.kind] || '◇'), make('span', 'node-kind', node.kind === 'pr' ? 'Pull request' : node.kind.charAt(0).toUpperCase() + node.kind.slice(1)), make('span', `node-state ${node.status}`, node.status))
      card.append(header, make('h3', '', node.title), make('p', 'node-description', node.description || 'An idea waiting to take shape. Add context to get started.'))
      const footer = make('div', 'node-footer')
      footer.append(make('span', '', `${node.attachments.length} sources`), make('span', '', `${node.messages.length} messages`), make('span', 'node-open', '↗'))
      card.append(footer)
      if (node.status === 'running' || node.status === 'starting') card.append(make('div', 'node-running'))
      this.plane.append(card)
    }
    this.drawEdges()
    this.el.querySelector('.canvas-empty').hidden = this.graph.nodes.length !== 0
    this.transform()
  },
  drawEdges() {
    this.svg.replaceChildren()
    for (const edge of this.graph.edges) {
      const from = this.graph.nodes.find(n => n.id === edge.from), to = this.graph.nodes.find(n => n.id === edge.to)
      if (!from || !to) continue
      const x1 = from.x + 280, y1 = from.y + 90, x2 = to.x, y2 = to.y + 90
      const curve = Math.max(60, Math.abs(x2 - x1) / 2)
      const path = document.createElementNS(svgNS, 'path')
      path.setAttribute('d', `M ${x1} ${y1} C ${x1 + curve} ${y1}, ${x2 - curve} ${y2}, ${x2} ${y2}`)
      this.svg.append(path)
      const circle = document.createElementNS(svgNS, 'circle')
      circle.setAttribute('cx', x2); circle.setAttribute('cy', y2); circle.setAttribute('r', 4)
      this.svg.append(circle)
      const label = document.createElementNS(svgNS, 'text')
      label.setAttribute('x', (x1 + x2) / 2); label.setAttribute('y', (y1 + y2) / 2 - 12)
      label.textContent = edge.label; this.svg.append(label)
    }
  },
  transform() {
    this.plane.style.transform = `translate(${this.view.x}px, ${this.view.y}px) scale(${this.view.scale})`
    this.el.querySelector('.zoom-value').textContent = `${Math.round(this.view.scale * 100)}%`
    this.el.style.backgroundPosition = `${this.view.x}px ${this.view.y}px`
    this.el.style.backgroundSize = `${24 * this.view.scale}px ${24 * this.view.scale}px`
  },
  zoom(scale, x = this.el.clientWidth / 2, y = this.el.clientHeight / 2) {
    scale = Math.min(2, Math.max(0.25, scale))
    this.view.x = x - (x - this.view.x) * scale / this.view.scale
    this.view.y = y - (y - this.view.y) * scale / this.view.scale
    this.view.scale = scale; this.transform()
  },
  fit() {
    const nodes = this.graph.nodes
    if (!nodes.length) return
    const minX = Math.min(...nodes.map(n => n.x)), minY = Math.min(...nodes.map(n => n.y))
    const width = Math.max(...nodes.map(n => n.x + 280)) - minX
    const height = Math.max(...nodes.map(n => n.y + 200)) - minY
    const scale = Math.min(1, Math.max(0.25, Math.min((this.el.clientWidth - 100) / width, (this.el.clientHeight - 100) / height)))
    this.view = {scale, x: (this.el.clientWidth - width * scale) / 2 - minX * scale, y: (this.el.clientHeight - height * scale) / 2 - minY * scale}
    this.transform()
  }
}

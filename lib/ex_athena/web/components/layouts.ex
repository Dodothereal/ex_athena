defmodule ExAthena.Web.Layouts do
  use Phoenix.Component
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" style="height:100%">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>ExAthena</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <link rel="stylesheet" href="/assets/vendor/xterm/xterm.css" />
        <script src="/assets/vendor/xterm/xterm.js"></script>
        <script src="/assets/vendor/xterm/addon-fit.js"></script>
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/assets/phoenix/phoenix.mjs",
              "phoenix_live_view": "/assets/phoenix_live_view/phoenix_live_view.esm.js"
            }
          }
        </script>
        <script>
          (function(){
            var t = localStorage.getItem("ex_athena.theme")
            if (t) document.documentElement.dataset.theme = t
          })()
        </script>
        <script type="module">
          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"

          // ── Minimal Markdown renderer ──────────────────────────────────────
          function escHtml(s) {
            return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
          }

          function inlineMd(s) {
            // inline code first (protect from bold/italic)
            s = s.replace(/`([^`]+)`/g, (_,c) => `<code class="md-code">${escHtml(c)}</code>`)
            // bold+italic, bold, italic
            s = s.replace(/\*\*\*([^*]+)\*\*\*/g, "<strong><em>$1</em></strong>")
            s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
            s = s.replace(/\*([^*]+)\*/g, "<em>$1</em>")
            // links
            s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,
              '<a class="md-link" href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
            return s
          }

          function renderMarkdown(raw) {
            // Extract fenced code blocks before line processing
            const blocks = []
            let text = raw.replace(/```(\w*)\n?([\s\S]*?)```/gm, (_, lang, code) => {
              const idx = blocks.length
              const label = lang ? `<span class="md-fence-lang">${escHtml(lang)}</span>` : ""
              blocks.push(
                `<div class="md-fence">${label}<pre><code>${escHtml(code.trim())}</code></pre></div>`
              )
              return `\x00BLOCK${idx}\x00`
            })

            const lines = text.split("\n")
            let html = ""
            let listKind = null

            const closeList = () => {
              if (listKind) { html += `</${listKind}>` ; listKind = null }
            }

            for (const line of lines) {
              // Restore code blocks
              const restored = line.replace(/\x00BLOCK(\d+)\x00/g, (_, i) => blocks[+i])

              // Headings
              const h = restored.match(/^(#{1,3}) (.+)$/)
              if (h) {
                closeList()
                const n = h[1].length
                html += `<h${n} class="md-h${n}">${inlineMd(h[2])}</h${n}>`
                continue
              }
              // Unordered list
              const ul = restored.match(/^[-*] (.+)$/)
              if (ul) {
                if (listKind !== "ul") { closeList(); html += `<ul class="md-ul">`; listKind = "ul" }
                html += `<li>${inlineMd(ul[1])}</li>`
                continue
              }
              // Ordered list
              const ol = restored.match(/^\d+\. (.+)$/)
              if (ol) {
                if (listKind !== "ol") { closeList(); html += `<ol class="md-ol">`; listKind = "ol" }
                html += `<li>${inlineMd(ol[1])}</li>`
                continue
              }
              // Horizontal rule
              if (/^---+$/.test(restored.trim())) {
                closeList(); html += `<hr class="md-hr">` ; continue
              }
              // Block restore (fence)
              if (restored.includes("<div class=\"md-fence\"")) {
                closeList(); html += restored ; continue
              }
              // Empty line
              if (restored.trim() === "") {
                closeList(); html += `<br>` ; continue
              }
              // Normal line
              if (listKind) {
                html += `<li>${inlineMd(restored)}</li>`
              } else {
                html += `<span>${inlineMd(restored)}</span><br>`
              }
            }
            closeList()
            return html
          }

          // ── LiveView hooks ─────────────────────────────────────────────────
          const THEME_KEY = "ex_athena.theme"
          const applyTheme = (light) => {
            document.documentElement.dataset.theme = light ? "light" : "dark"
            localStorage.setItem(THEME_KEY, light ? "light" : "dark")
          }

          const Hooks = {
            ThemeToggle: {
              mounted() {
                const input = this.el.querySelector("input[type=checkbox]")
                const light = localStorage.getItem(THEME_KEY) === "light"
                if (input) input.checked = light
                document.documentElement.dataset.theme = light ? "light" : "dark"
                if (input) {
                  input.addEventListener("change", () => applyTheme(input.checked))
                }
              }
            },
            ScrollToBottom: {
              mounted()  { this.scrollToBottom() },
              updated()  { this.scrollToBottom() },
              scrollToBottom() { this.el.scrollTop = this.el.scrollHeight }
            },

            // A real terminal via xterm.js over the erlexec PTY. The hook
            // owns its DOM (phx-update="ignore"); the server streams raw VT
            // bytes (base64) which xterm renders — neovim, htop, colors,
            // the real prompt, all work. Keystrokes stream back per-char.
            Terminal: {
              mounted() {
                const id = this.el.dataset.termId
                const term = new Terminal({
                  cursorBlink: true,
                  fontFamily: "JetBrains Mono, Fira Code, monospace",
                  fontSize: 12,
                  theme: { background: "#0e0e12", foreground: "#dde1f0" }
                })
                const fit = new FitAddon.FitAddon()
                term.loadAddon(fit)
                term.open(this.el)
                fit.fit()

                this.term = term
                this.fit = fit

                // keystrokes -> server -> pty
                term.onData((data) => this.pushEvent("term_input", { id, data }))

                // pty output (base64 raw bytes) -> xterm
                this.handleEvent("term_out", ({ id: outId, b64 }) => {
                  if (outId !== id) return
                  const bin = atob(b64)
                  const bytes = new Uint8Array(bin.length)
                  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
                  term.write(bytes)
                })

                // fit on container resize. Skip while hidden (display:none →
                // 0 size): fitting at 0 clamps xterm to a tiny grid, so the
                // panel looks resized when shown again.
                const sendResize = () => {
                  if (!this.el.clientWidth || !this.el.clientHeight) return
                  try { this.fit.fit() } catch (_e) { return }
                  this.pushEvent("term_resize", { id, cols: term.cols, rows: term.rows })
                }
                this.ro = new ResizeObserver(sendResize)
                this.ro.observe(this.el)
                sendResize()

                // Re-fit when the Terminal tab is re-activated (a display
                // change doesn't reliably trigger ResizeObserver).
                this.handleEvent("term_fit", () => sendResize())

                // Ask the server to replay captured scrollback (covers the
                // mount race for the first prompt + full reconnects).
                this.pushEvent("term_ready", { id })
              },
              destroyed() {
                this.ro && this.ro.disconnect()
                this.term && this.term.dispose()
              }
            },

            MarkdownRender: {
              mounted()  { this.render() },
              updated()  { this.render() },
              render() {
                const raw = this.el.dataset.raw
                if (raw !== undefined) this.el.innerHTML = renderMarkdown(raw)
              }
            },

            SubmitOnEnter: {
              mounted() {
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault()
                    this.el.closest("form").dispatchEvent(
                      new Event("submit", {bubbles: true, cancelable: true})
                    )
                    setTimeout(() => { this.el.value = "" }, 0)
                  }
                })
                // When the run pauses to ask a question, focus the input so the
                // user can answer immediately.
                this.handleEvent("focus-chat-input", () => {
                  setTimeout(() => this.el.focus(), 0)
                })
              }
            },

            PathInput: {
              mounted() {
                this.el.focus()
                this.el.setSelectionRange(this.el.value.length, this.el.value.length)
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Tab") {
                    e.preventDefault()
                    this.pushEvent("tab_complete", {path: this.el.value})
                  }
                })
                this.handleEvent("tab_fill", ({value}) => {
                  this.el.value = value
                  // tell the server the new value so validation updates
                  this.pushEvent("modal_path_change", {path: value})
                })
              }
            },

            ImageInput: {
              mounted() {
                const bar = this.el
                const textarea = bar.querySelector("textarea")
                const fileInput = bar.querySelector("#image-file-input")

                const readAndPush = (file) => {
                  if (!file || !file.type.startsWith("image/")) return
                  const reader = new FileReader()
                  reader.onload = (e) => {
                    const [header, data] = e.target.result.split(",")
                    const type = header.match(/:(.*?);/)[1]
                    this.pushEvent("attach_image", {data, type})
                  }
                  reader.readAsDataURL(file)
                }

                if (textarea) {
                  textarea.addEventListener("paste", (e) => {
                    const items = Array.from(e.clipboardData?.items || [])
                    const imgItems = items.filter(i => i.type.startsWith("image/"))
                    if (imgItems.length > 0) {
                      e.preventDefault()
                      imgItems.forEach(i => readAndPush(i.getAsFile()))
                    }
                  })
                }

                bar.addEventListener("dragover", (e) => {
                  e.preventDefault()
                  bar.classList.add("drag-over")
                })

                bar.addEventListener("dragleave", (e) => {
                  if (!bar.contains(e.relatedTarget)) bar.classList.remove("drag-over")
                })

                bar.addEventListener("drop", (e) => {
                  e.preventDefault()
                  bar.classList.remove("drag-over")
                  Array.from(e.dataTransfer.files).forEach(readAndPush)
                })

                if (fileInput) {
                  fileInput.addEventListener("change", (e) => {
                    Array.from(e.target.files).forEach(readAndPush)
                    e.target.value = ""
                  })
                }
              }
            },

            // Resizable split-pane divider inside .chat-main. Mouse-drag on
            // .chat-divider updates --left-w / --right-w CSS variables on
            // the .chat-main element (this.el). Ratio persists in
            // localStorage. Clamped 20%–80%.
            SplitResize: {
              mounted() {
                const STORAGE_KEY = "ex_athena.split_ratio"
                const MIN = 0.20, MAX = 0.80
                const apply = (ratio) => {
                  const r = Math.max(MIN, Math.min(MAX, ratio))
                  this.el.style.setProperty("--left-w", `${r}fr`)
                  this.el.style.setProperty("--right-w", `${1 - r}fr`)
                  return r
                }

                const stored = parseFloat(localStorage.getItem(STORAGE_KEY))
                if (!isNaN(stored)) apply(stored)

                const divider = this.el.querySelector("#chat-divider")
                if (!divider) return

                divider.addEventListener("mousedown", (e) => {
                  e.preventDefault()
                  divider.classList.add("dragging")
                  document.body.style.cursor = "col-resize"
                  document.body.style.userSelect = "none"

                  const onMove = (ev) => {
                    const rect = this.el.getBoundingClientRect()
                    const ratio = (ev.clientX - rect.left) / rect.width
                    apply(ratio)
                  }

                  const onUp = () => {
                    divider.classList.remove("dragging")
                    document.body.style.cursor = ""
                    document.body.style.userSelect = ""
                    const left = parseFloat(getComputedStyle(this.el).getPropertyValue("--left-w"))
                    if (!isNaN(left)) localStorage.setItem(STORAGE_KEY, String(left))
                    document.removeEventListener("mousemove", onMove)
                    document.removeEventListener("mouseup", onUp)
                  }

                  document.addEventListener("mousemove", onMove)
                  document.addEventListener("mouseup", onUp)
                })

                // Left pane can request the right pane to scroll to a tool
                // entry by tool_call_id (e.g. clicking a one-liner).
                this.handleEvent("focus-detail", ({tool_call_id}) => {
                  const node = this.el.querySelector(
                    `.detail-entry[data-tool-call-id="${tool_call_id}"]`
                  )
                  if (!node) return
                  node.scrollIntoView({behavior: "smooth", block: "center"})
                  node.classList.add("detail-entry--focused")
                  setTimeout(() => node.classList.remove("detail-entry--focused"), 1200)
                })
              }
            }
          }

          // ── Bootstrap LiveSocket ───────────────────────────────────────────
          const csrfToken = document.querySelector("meta[name='csrf-token']").content
          const liveSocket = new LiveSocket("/live", Socket, {
            params: {_csrf_token: csrfToken},
            hooks: Hooks
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </head>
      <body style="height:100%;margin:0">
        {@inner_content}
      </body>
    </html>
    """
  end
end

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
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/assets/phoenix/phoenix.mjs",
              "phoenix_live_view": "/assets/phoenix_live_view/phoenix_live_view.esm.js"
            }
          }
        </script>
        <script type="module">
          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"

          const csrfToken = document.querySelector("meta[name='csrf-token']").content

          const Hooks = {
            ScrollToBottom: {
              mounted()  { this.scrollToBottom() },
              updated()  { this.scrollToBottom() },
              scrollToBottom() {
                this.el.scrollTop = this.el.scrollHeight
              }
            },
            AutoFocus: {
              mounted()  { this.el.focus() },
              updated()  { if (!this.el.disabled) this.el.focus() }
            },
            SubmitOnEnter: {
              mounted() {
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault()
                    this.el.closest("form").dispatchEvent(new Event("submit", {bubbles: true}))
                  }
                })
              }
            }
          }

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

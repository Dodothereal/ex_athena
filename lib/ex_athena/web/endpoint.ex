defmodule ExAthena.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :ex_athena

  @session_options [
    store: :cookie,
    key: "_ex_athena_key",
    signing_salt: "ex_athena_web",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Serve pre-built ESM files from each package's priv/static so we
  # can use an importmap — no npm or esbuild step required.
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false

  plug Plug.Static,
    at: "/assets",
    from: {:ex_athena, "priv/web/static"},
    gzip: false

  plug Plug.Session, @session_options

  plug ExAthena.Web.Router
end

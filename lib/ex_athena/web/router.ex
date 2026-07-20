defmodule ExAthena.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExAthena.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Shared-secret gate (no-op on the default loopback bind). The plug only
    # covers HTTP; the on_mount hook below is the real gate for the websocket.
    plug ExAthena.Web.Auth
  end

  scope "/", ExAthena.Web.Live do
    pipe_through :browser

    # Both routes mount the same LiveView. `/c/:session_id` carries the stable
    # session id in the URL so a websocket reconnect re-mounts with the same id
    # and can re-attach to an in-flight run (see ChatLive.mount + RunServer).
    live_session :chat, on_mount: ExAthena.Web.Auth do
      live "/", ChatLive
      live "/c/:session_id", ChatLive
    end
  end
end

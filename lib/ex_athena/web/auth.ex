defmodule ExAthena.Web.Auth do
  @moduledoc """
  Shared-secret gate for the web UI.

  The web UI hands whoever reaches it an arbitrary-command agent console
  (client-chosen `cwd`, bash/write tools, a real interactive terminal), so
  exposure beyond loopback must be authenticated. `mix athena.web` decides
  the policy: bound to loopback there is no token and this module is a
  no-op; bound wider (`--lan` / `--host`) a token is required and stored
  under `config :ex_athena, ExAthena.Web.Auth, token: ...`.

  Enforcement happens twice, because plugs do not run on the LiveView
  websocket:

    * `call/2` (plug, HTTP entry) — accepts `?token=<secret>` once, stamps
      it into the session, and redirects to the same path without the query
      token; otherwise requires an already-stamped session. Everything else
      is a 403.
    * `on_mount/4` (websocket entry) — re-verifies the session token on
      every LiveView mount. This is the gate that actually protects the
      high-privilege events; a halted mount redirects to `/`, where the
      plug renders the 403.

  Tokens are compared with `Plug.Crypto.secure_compare/2`, and the session
  stores the token itself, so restarting the server with a fresh secret
  invalidates previously authorized browsers.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key "athena_web_token"
  @token_param "token"

  @doc "The token required for access, or `nil` when the UI is open (loopback)."
  @spec required_token() :: String.t() | nil
  def required_token do
    Application.get_env(:ex_athena, __MODULE__, [])[:token]
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case required_token() do
      nil ->
        conn

      token ->
        conn = fetch_query_params(conn)

        cond do
          valid?(get_session(conn, @session_key), token) ->
            conn

          valid?(conn.query_params[@token_param], token) ->
            # Stamp the session and strip the token from the URL so it
            # doesn't linger in history / referrers.
            conn
            |> put_session(@session_key, token)
            |> put_resp_header("location", conn.request_path)
            |> send_resp(302, "")
            |> halt()

          true ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(403, "Forbidden: this ExAthena web UI requires an access token.\n")
            |> halt()
        end
    end
  end

  @doc """
  LiveView `on_mount` hook — verifies the session token on the websocket,
  where plugs never run.
  """
  def on_mount(:default, _params, session, socket) do
    case required_token() do
      nil ->
        {:cont, socket}

      token ->
        if valid?(session[@session_key], token) do
          {:cont, socket}
        else
          {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
        end
    end
  end

  defp valid?(candidate, token) when is_binary(candidate) do
    Plug.Crypto.secure_compare(candidate, token)
  end

  defp valid?(_candidate, _token), do: false
end

defmodule ExAthena.Web.AuthTest do
  @moduledoc """
  The shared-secret gate for the web UI (issue #134).

  Two enforcement points, both tested here:

    * the plug — HTTP entry: verifies `?token=` or an already-authorized
      session, and stamps the token into the session so the websocket can
      re-verify it;
    * the `on_mount` hook — the websocket entry: plugs do not run on the
      LiveView socket, so this is the gate that actually protects the
      high-privilege LiveView events.
  """
  # async: false — the required token lives in the (global) application env.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ExAthena.Web.Auth

  @session_key "athena_web_token"

  setup do
    on_exit(fn -> Application.delete_env(:ex_athena, Auth) end)
    :ok
  end

  defp require_token(token) do
    Application.put_env(:ex_athena, Auth, token: token)
  end

  defp call(conn), do: Auth.call(conn, Auth.init([]))

  describe "plug — no token configured (loopback default)" do
    test "passes every request through untouched" do
      conn = conn(:get, "/") |> init_test_session(%{}) |> call()

      refute conn.halted
      refute conn.status
    end
  end

  describe "plug — token required" do
    setup do
      require_token("s3cret")
      :ok
    end

    test "denies a request with no token at all" do
      conn = conn(:get, "/") |> init_test_session(%{}) |> call()

      assert conn.halted
      assert conn.status == 403
    end

    test "denies a wrong query token" do
      conn = conn(:get, "/?token=wrong") |> init_test_session(%{}) |> call()

      assert conn.halted
      assert conn.status == 403
    end

    test "denies a stale session token (server restarted with a new secret)" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{@session_key => "old-secret"})
        |> call()

      assert conn.halted
      assert conn.status == 403
    end

    test "accepts a valid query token, stores it in the session, and strips it from the URL" do
      conn = conn(:get, "/?token=s3cret") |> init_test_session(%{}) |> call()

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/"]
      assert get_session(conn, @session_key) == "s3cret"
    end

    test "the redirect keeps the request path" do
      conn = conn(:get, "/c/abc123?token=s3cret") |> init_test_session(%{}) |> call()

      assert get_resp_header(conn, "location") == ["/c/abc123"]
    end

    test "accepts an already-authorized session without a query token" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{@session_key => "s3cret"})
        |> call()

      refute conn.halted
      refute conn.status
    end
  end

  describe "on_mount — websocket gate" do
    test "continues when no token is required" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, ^socket} = Auth.on_mount(:default, %{}, %{}, socket)
    end

    test "continues when the session carries the required token" do
      require_token("s3cret")
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, ^socket} =
               Auth.on_mount(:default, %{}, %{@session_key => "s3cret"}, socket)
    end

    test "halts with a redirect when the session has no token" do
      require_token("s3cret")

      assert {:halt, socket} = Auth.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})
      assert {:redirect, %{to: "/"}} = socket.redirected
    end

    test "halts on a wrong session token" do
      require_token("s3cret")

      assert {:halt, _socket} =
               Auth.on_mount(:default, %{}, %{@session_key => "nope"}, %Phoenix.LiveView.Socket{})
    end
  end
end

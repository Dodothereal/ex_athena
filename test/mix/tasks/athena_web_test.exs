defmodule Mix.Tasks.Athena.WebTest do
  @moduledoc """
  Option parsing and endpoint configuration for `mix athena.web`.

  The security-relevant invariants (issue #134): the server binds loopback
  by default, non-loopback binding is an explicit opt-in that always carries
  an auth token, and the websocket origin check is never disabled.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Athena.Web

  describe "settings!/2 — bind address" do
    test "binds 127.0.0.1 by default with no auth token" do
      settings = Web.settings!([], %{})

      assert settings.ip == {127, 0, 0, 1}
      assert settings.host == "127.0.0.1"
      assert settings.port == 4000
      assert settings.token == nil
    end

    test "--port only changes the port, not the bind address" do
      settings = Web.settings!(["--port", "5123"], %{})

      assert settings.port == 5123
      assert settings.ip == {127, 0, 0, 1}
      assert settings.token == nil
    end

    test "--lan binds all interfaces" do
      settings = Web.settings!(["--lan"], %{})

      assert settings.ip == {0, 0, 0, 0}
      assert settings.host == "0.0.0.0"
    end

    test "--host accepts an explicit address" do
      settings = Web.settings!(["--host", "192.168.1.50"], %{})

      assert settings.ip == {192, 168, 1, 50}
      assert settings.host == "192.168.1.50"
    end

    test "--host localhost resolves to loopback and stays tokenless" do
      settings = Web.settings!(["--host", "localhost"], %{})

      assert settings.ip == {127, 0, 0, 1}
      assert settings.token == nil
    end

    test "an unparsable --host raises a Mix error" do
      assert_raise Mix.Error, ~r/host/i, fn ->
        Web.settings!(["--host", "not an address"], %{})
      end
    end
  end

  describe "settings!/2 — auth token" do
    test "--lan generates a token when none is supplied" do
      settings = Web.settings!(["--lan"], %{})

      assert is_binary(settings.token)
      # 16 bytes of entropy, url-base64 encoded without padding
      assert byte_size(settings.token) >= 22
    end

    test "generated tokens are unique per invocation" do
      refute Web.settings!(["--lan"], %{}).token == Web.settings!(["--lan"], %{}).token
    end

    test "--token wins over generation on a LAN bind" do
      settings = Web.settings!(["--lan", "--token", "sesame"], %{})

      assert settings.token == "sesame"
    end

    test "ATHENA_WEB_TOKEN env var is used when no --token is given" do
      settings = Web.settings!(["--lan"], %{"ATHENA_WEB_TOKEN" => "from-env"})

      assert settings.token == "from-env"
    end

    test "--token beats the env var" do
      settings = Web.settings!(["--token", "flag"], %{"ATHENA_WEB_TOKEN" => "env"})

      assert settings.token == "flag"
    end

    test "an explicit --token gates even a loopback bind" do
      settings = Web.settings!(["--token", "sesame"], %{})

      assert settings.ip == {127, 0, 0, 1}
      assert settings.token == "sesame"
    end
  end

  describe "endpoint_config/1" do
    test "propagates bind ip and port, and never disables the origin check" do
      config = Web.settings!([], %{}) |> Web.endpoint_config()

      assert config[:http][:ip] == {127, 0, 0, 1}
      assert config[:http][:port] == 4000
      assert config[:check_origin] == :conn
      assert config[:server] == true
    end

    test "keeps check_origin on for LAN binds too" do
      config = Web.settings!(["--lan", "--port", "8080"], %{}) |> Web.endpoint_config()

      assert config[:http][:ip] == {0, 0, 0, 0}
      assert config[:http][:port] == 8080
      assert config[:check_origin] == :conn
    end
  end
end

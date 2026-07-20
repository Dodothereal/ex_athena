defmodule Mix.Tasks.Athena.Web do
  @shortdoc "Start the ExAthena web UI"

  @moduledoc """
  Starts the ExAthena web chat UI, bound to localhost by default.

      mix athena.web
      mix athena.web --port 4000
      mix athena.web --lan

  Opens a Phoenix LiveView chat interface backed by the same agent loop as
  `mix athena.chat`. Provider, model, and mode are configurable in the sidebar.

  The UI is an arbitrary-command agent console (it runs bash/write tools in a
  browser-chosen directory), so by default it binds `127.0.0.1` and is only
  reachable from this machine. Exposing it more widely is an explicit opt-in
  (`--lan` or `--host`) and always requires a shared-secret token: one is
  generated (or taken from `--token` / the `ATHENA_WEB_TOKEN` env var) and
  printed as part of the startup URL — open that tokened URL once per browser.

  For a full walkthrough — sidebar controls, session persistence, JSON provider
  setup, and screenshot tour — see the [Web UI guide](guides/web.md).

  ## Flags

    * `--port PORT` — HTTP port (default 4000).
    * `--lan` — bind all interfaces (`0.0.0.0`) instead of loopback. Requires
      a token (auto-generated when none is supplied).
    * `--host HOST` — bind an explicit IP address (or `localhost`). Any
      non-loopback host requires a token, like `--lan`.
    * `--token TOKEN` — the shared secret gating access. Optional on loopback
      (default: no token), auto-generated on non-loopback binds. The
      `ATHENA_WEB_TOKEN` env var is used when the flag is absent.
    * `--log` — also write log output to `log/phoenix_output.log` (in addition
      to the terminal).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start", [])

    settings = settings!(argv)

    if settings.log do
      path = ExAthena.LogFile.attach!()
      Mix.shell().info("Logging to #{path}")
    end

    Application.put_env(:ex_athena, ExAthena.Web.Endpoint, endpoint_config(settings))
    Application.put_env(:ex_athena, ExAthena.Web.Auth, token: settings.token)

    children = [
      {Phoenix.PubSub, name: ExAthena.PubSub},
      # Per-session run owners (ExAthena.Web.RunServer) live here so an in-flight
      # run survives LiveView reconnects and a remounting LiveView can re-attach.
      {Registry, keys: :unique, name: ExAthena.Web.RunRegistry},
      {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one},
      ExAthena.Web.Endpoint
    ]

    {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

    announce(settings)
    Process.sleep(:infinity)
  end

  @doc """
  Resolves argv (plus an env-var map, injectable for tests) into the runtime
  settings: bind ip/host, port, log flag, and the auth token (`nil` means
  open access, only allowed on loopback binds).
  """
  @spec settings!([String.t()], %{optional(String.t()) => String.t()}) :: %{
          ip: :inet.ip_address(),
          host: String.t(),
          port: pos_integer(),
          token: String.t() | nil,
          log: boolean()
        }
  def settings!(argv, env \\ System.get_env()) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [port: :integer, log: :boolean, lan: :boolean, host: :string, token: :string]
      )

    host =
      cond do
        parsed[:host] -> parsed[:host]
        parsed[:lan] -> "0.0.0.0"
        true -> "127.0.0.1"
      end

    ip = parse_ip!(host)
    token = parsed[:token] || blank_to_nil(env["ATHENA_WEB_TOKEN"]) || default_token(ip)

    %{
      ip: ip,
      host: host,
      port: parsed[:port] || 4000,
      token: token,
      log: parsed[:log] || false
    }
  end

  @doc """
  The `ExAthena.Web.Endpoint` config for the resolved settings.

  `check_origin: :conn` makes the websocket origin check require an exact
  scheme/host/port match against the connection — correct for a localhost
  UI on a configurable port, and still enforced on LAN binds.
  """
  def endpoint_config(settings) do
    [
      adapter: Bandit.PhoenixAdapter,
      http: [ip: settings.ip, port: settings.port],
      url: [host: url_host(settings), port: settings.port],
      check_origin: :conn,
      server: true,
      live_view: [signing_salt: "ex_athena_lv_salt_1"],
      secret_key_base: stable_key_base(),
      render_errors: [formats: [html: ExAthena.Web.ErrorHTML], layout: false],
      pubsub_server: ExAthena.PubSub
    ]
  end

  defp announce(settings) do
    url = "http://#{url_host(settings)}:#{settings.port}"

    case settings.token do
      nil ->
        Mix.shell().info("ExAthena web UI → #{url}")

      token ->
        Mix.shell().info("ExAthena web UI → #{url}/?token=#{token}")

        unless loopback?(settings.ip) do
          Mix.shell().info(
            "Listening on #{settings.host} — reachable beyond this machine. " <>
              "Access requires the token above (open the tokened URL once per browser)."
          )
        end
    end
  end

  defp url_host(%{ip: ip, host: host}) do
    cond do
      loopback?(ip) -> "localhost"
      ip == {0, 0, 0, 0} -> "localhost"
      true -> host
    end
  end

  defp parse_ip!("localhost"), do: {127, 0, 0, 1}

  defp parse_ip!(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        Mix.raise(
          "Invalid --host #{inspect(host)}: expected an IP address (e.g. 127.0.0.1, " <>
            "0.0.0.0, ::1) or \"localhost\""
        )
    end
  end

  # Loopback binds stay frictionless: no token unless one is configured
  # explicitly. Anything wider always gets a generated shared secret.
  defp default_token(ip) do
    if loopback?(ip) do
      nil
    else
      :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Persist the secret_key_base so session cookies survive restarts.
  # A fresh random key on every start causes the old session cookie to fail
  # CSRF validation, which triggers LiveView's reloadWithJitter (5–10 s delay).
  defp stable_key_base do
    key_file = Path.expand("~/.ex_athena/web/secret.key")
    File.mkdir_p!(Path.dirname(key_file))

    case File.read(key_file) do
      {:ok, key} when byte_size(key) >= 64 ->
        String.trim(key)

      _ ->
        key = :crypto.strong_rand_bytes(64) |> Base.encode64()
        File.write!(key_file, key)
        key
    end
  end
end

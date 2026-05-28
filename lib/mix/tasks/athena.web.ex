defmodule Mix.Tasks.Athena.Web do
  @shortdoc "Start the ExAthena web UI"

  @moduledoc """
  Starts the ExAthena web chat UI on localhost.

      mix athena.web
      mix athena.web --port 4000

  Opens a Phoenix LiveView chat interface backed by the same agent loop as
  `mix athena.chat`. Provider, model, and mode are configurable in the sidebar.

  For a full walkthrough — sidebar controls, session persistence, JSON provider
  setup, and screenshot tour — see the [Web UI guide](guides/web.md).

  ## Flags

    * `--port PORT` — HTTP port (default 4000).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start", [])

    {parsed, _rest, _invalid} = OptionParser.parse(argv, strict: [port: :integer])
    port = parsed[:port] || 4000

    Application.put_env(:ex_athena, ExAthena.Web.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {0, 0, 0, 0}, port: port],
      url: [host: "0.0.0.0", port: port],
      check_origin: false,
      server: true,
      live_view: [signing_salt: "ex_athena_lv_salt_1"],
      secret_key_base: stable_key_base(),
      render_errors: [formats: [html: ExAthena.Web.ErrorHTML], layout: false],
      pubsub_server: ExAthena.PubSub
    )

    children = [
      {Phoenix.PubSub, name: ExAthena.PubSub},
      ExAthena.Web.Endpoint
    ]

    {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

    Mix.shell().info("ExAthena web UI → http://localhost:#{port}")
    Process.sleep(:infinity)
  end

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

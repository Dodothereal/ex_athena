defmodule Mix.Tasks.Athena.Web do
  @shortdoc "Start the ExAthena web UI"

  @moduledoc """
  Starts the ExAthena web chat UI on localhost.

      mix athena.web
      mix athena.web --port 4000

  Opens a Phoenix LiveView chat interface backed by the same agent loop as
  `mix athena.chat`. Provider, model, and mode are configurable in the sidebar.

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
      live_view: [signing_salt: random_salt()],
      secret_key_base: random_key_base(),
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

  defp random_salt do
    :crypto.strong_rand_bytes(8) |> Base.encode64()
  end

  defp random_key_base do
    :crypto.strong_rand_bytes(64) |> Base.encode64()
  end
end

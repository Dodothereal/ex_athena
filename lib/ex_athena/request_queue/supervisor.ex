defmodule ExAthena.RequestQueue.Supervisor do
  @moduledoc """
  Supervisor for the `ExAthena.RequestQueue` GenServer.

  Started by `ExAthena.Application` when the request queue is enabled:

      config :ex_athena, :request_queue, enabled: true

  The feature is opt-in and disabled by default. When disabled, the supervisor
  is not started and `ExAthena.RequestQueue.acquire/2` / `release/1` are no-ops.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [ExAthena.RequestQueue]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

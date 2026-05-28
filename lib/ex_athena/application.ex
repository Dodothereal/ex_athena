defmodule ExAthena.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [
        # Subagents spawn under this supervisor so a sub-loop crash can't
        # take down the parent run. `Task.Supervisor.async_nolink` + timeout
        # gives us unlinked concurrency we can reap on deadline.
        {Task.Supervisor, name: ExAthena.Tasks}
      ]
      |> maybe_add_sweeper()

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAthena.Supervisor)
  end

  # WorktreeSweeper is a transient one-shot at boot. We skip it in the test
  # environment so unit tests don't trigger filesystem GC; tests opt in
  # explicitly when they want to exercise it.
  defp maybe_add_sweeper(children) do
    children =
      if Application.get_env(:ex_athena, :enable_worktree_sweeper, true) do
        children ++ [ExAthena.Agents.WorktreeSweeper]
      else
        children
      end

    children =
      if Application.get_env(:ex_athena, :enable_checkpoint_sweeper, true) do
        children ++ [ExAthena.Checkpoint.Sweeper]
      else
        children
      end

    # Always supervise the in-memory and ETS stores — both used by tests
    # and Session configs. Cheap to keep around (ETS tables).
    children =
      children ++
        [
          ExAthena.Sessions.Stores.InMemory,
          ExAthena.Sessions.Stores.ETS,
          ExAthena.ContextWindow,
          ExAthena.ModelDiscovery
        ]

    children =
      if Application.get_env(:ex_athena, :enable_provider_registry, true) do
        children ++ [ExAthena.ProviderRegistry]
      else
        children
      end

    children =
      if Application.get_env(:ex_athena, :enable_lsp, true) do
        children ++ [ExAthena.Lsp.Supervisor]
      else
        children
      end

    children =
      if Application.get_env(:ex_athena, :enable_mcp, true) do
        children ++ [ExAthena.Mcp.Supervisor]
      else
        children
      end

    if Application.get_env(:ex_athena, :request_queue, [])[:enabled] do
      children ++ [ExAthena.RequestQueue.Supervisor]
    else
      children
    end
  end
end

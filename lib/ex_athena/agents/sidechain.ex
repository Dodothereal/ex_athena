defmodule ExAthena.Agents.Sidechain do
  @moduledoc """
  Writes a subagent's transcript to disk so it doesn't bloat the
  parent's context.

  Path: `<cwd>/.exathena/sessions/<parent_session_id>/sidechains/<subagent_id>.jsonl`.

  Each line is a single JSON object: prompt, opts (subset), result
  text + termination metadata. The parent only ever sees the final
  text via `Result.text`; the full transcript persists here.

  PR5 replaces this inline writer with the `ExAthena.Sessions.Store`
  behaviour and the JSONL store implementation. Until then, this
  bare-bones writer keeps PR4 self-contained.
  """

  @doc """
  Persist a subagent's full transcript. `result` is whatever
  `ExAthena.Loop.run/2` returned (`{:ok, %Result{}}` or
  `{:error, term}`).

  Returns `:ok`. Errors are silently logged; sidechain writes are
  best-effort.
  """
  @spec write(map()) :: :ok
  def write(%{
        cwd: cwd,
        parent_session_id: parent_session_id,
        subagent_id: subagent_id,
        prompt: prompt,
        opts: opts,
        result: result
      })
      when is_binary(parent_session_id) and is_binary(subagent_id) do
    dir = Path.join([cwd, ".exathena", "sessions", parent_session_id, "sidechains"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{subagent_id}.jsonl")

    payload = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      subagent_id: subagent_id,
      parent_session_id: parent_session_id,
      prompt: prompt,
      opts: serializable_opts(opts),
      result: serializable_result(result)
    }

    line = Jason.encode!(payload) <> "\n"
    _ = File.write(path, line, [:append])
    :ok
  rescue
    _ -> :ok
  end

  def write(_), do: :ok

  defp serializable_opts(opts) when is_list(opts) do
    # Best-effort serialisation — every value goes through `inspect/1` so
    # the JSONL line never blows up on closures, PIDs, or refs that may
    # have been folded in via `:assigns`.
    opts |> Enum.map(fn {k, v} -> {k, inspect(v)} end) |> Enum.into(%{})
  end

  defp serializable_opts(_), do: %{}

  defp serializable_result({:ok, %{text: text} = r}) do
    %{
      ok: true,
      text: text,
      finish_reason: Map.get(r, :finish_reason),
      iterations: Map.get(r, :iterations),
      tool_calls_made: Map.get(r, :tool_calls_made),
      duration_ms: Map.get(r, :duration_ms),
      cost_usd: Map.get(r, :cost_usd),
      # Persist the captured reasoning + task state so a worker's run can be
      # post-mortem'd (conclusion quality, what it learned) — without these
      # a blank-text worker's sidechain is opaque.
      conclusions: Map.get(r, :conclusions, []),
      todos: Map.get(r, :todos, [])
    }
  end

  defp serializable_result({:error, reason}) do
    %{ok: false, error: inspect(reason)}
  end

  defp serializable_result(other), do: %{ok: false, raw: inspect(other)}
end

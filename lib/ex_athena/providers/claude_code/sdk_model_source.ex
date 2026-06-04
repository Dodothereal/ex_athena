defmodule ExAthena.Providers.ClaudeCode.SDKModelSource do
  @moduledoc """
  Real `ExAthena.Providers.ClaudeCode.ModelSource` backed by the `claude_code` SDK.

  The CLI reports its supported models through the control-protocol initialize
  handshake, which completes asynchronously after the session starts. We open a
  short-lived session, poll `ClaudeCode.Session.supported_models/1` until the
  handshake lands (or a deadline passes), then stop the session. No query is
  issued, and the session runs in `:plan` mode so it never touches the workspace.
  """
  @behaviour ExAthena.Providers.ClaudeCode.ModelSource

  alias ExAthena.Providers.ClaudeCode.ModelSource

  # How long to wait for the CLI handshake before giving up. The first run may
  # resolve/auto-install the CLI, so allow generous headroom.
  @deadline_ms 15_000
  @poll_interval_ms 100

  @impl ModelSource
  def supported_models do
    if Code.ensure_loaded?(ClaudeCode) do
      open_and_read()
    else
      {:error, :claude_code_not_installed}
    end
  end

  defp open_and_read do
    case ClaudeCode.start_link(permission_mode: :plan) do
      {:ok, session} ->
        try do
          poll(session, @deadline_ms)
        after
          ClaudeCode.stop(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Poll until the handshake reports a non-empty model list or the deadline
  # passes. `supported_models/1` returns `{:ok, []}` before the handshake lands.
  defp poll(_session, remaining) when remaining <= 0, do: {:error, :timeout}

  defp poll(session, remaining) do
    case ClaudeCode.Session.supported_models(session) do
      {:ok, [_ | _] = models} ->
        {:ok, models}

      {:ok, []} ->
        Process.sleep(@poll_interval_ms)
        poll(session, remaining - @poll_interval_ms)

      {:error, _reason} = error ->
        error
    end
  end
end

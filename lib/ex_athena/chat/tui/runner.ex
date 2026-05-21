defmodule ExAthena.Chat.Tui.Runner do
  @moduledoc """
  Bridges `ExAthena.run/2` with the `ExAthena.Chat.Tui` App process.

  Owns three responsibilities:

    * `build_run_opts/2` — the keyword list passed to `ExAthena.run/2`, with
      sane defaults for local providers (Ollama, llama.cpp) and a finite-but
      generous 24h request timeout so a slow-thinking local model doesn't
      trip the default 60s timeout.
    * `select_initial_model/2` — reconciles a desired model against what's
      actually installed, returning `{:ok, _}`, `{:fallback, _}`, or
      `{:error, _}` so the App can decide how to surface the result.
    * `start/2` / `start/3` — spawn an unsupervised `Task` that runs the
      agent loop, sending `{:athena_event, _}` for each loop event and a
      terminal `{:athena_done, _}` or `{:athena_error, _}` when the run
      finishes. The task body is wrapped in `try/rescue/catch` so failures
      always reach the App (per the CLAUDE.md "Task.start silently swallows
      crashes" rule).
  """

  alias ExAthena.Chat.Session

  @run_timeout_ms 24 * 60 * 60 * 1000

  @spec start(Session.t(), pid()) :: pid()
  def start(%Session{} = session, target_pid), do: start(session, target_pid, [])

  @spec start(Session.t(), pid(), keyword()) :: pid()
  def start(%Session{} = session, target_pid, extra_opts) when is_pid(target_pid) do
    callback = build_callback(target_pid)
    opts = session |> build_run_opts(callback) |> Keyword.merge(extra_opts)

    {:ok, pid} =
      Task.start(fn ->
        try do
          case ExAthena.run(nil, opts) do
            {:ok, result} -> send(target_pid, {:athena_done, result})
            {:error, reason} -> send(target_pid, {:athena_error, reason})
          end
        rescue
          e -> send(target_pid, {:athena_error, {:exception, e, __STACKTRACE__}})
        catch
          kind, reason -> send(target_pid, {:athena_error, {kind, reason}})
        end
      end)

    pid
  end

  @spec build_callback(pid()) :: (term() -> :ok)
  def build_callback(target_pid) when is_pid(target_pid) do
    fn event ->
      send(target_pid, {:athena_event, event})
      :ok
    end
  end

  @spec build_run_opts(Session.t(), (term() -> term())) :: keyword()
  def build_run_opts(%Session{} = session, callback) when is_function(callback, 1) do
    base = [
      provider: session.provider,
      model: session.model,
      mode: session.mode,
      tools: session.tools,
      messages: session.messages,
      permission_mode: session.permission_mode,
      on_event: callback,
      timeout_ms: @run_timeout_ms
    ]

    apply_default_base_url(base, session.provider)
  end

  @spec select_initial_model(String.t(), {:ok, [String.t()]} | {:error, term()}) ::
          {:ok, String.t()}
          | {:fallback, String.t()}
          | {:error, :no_models | :ollama_unreachable | :llamacpp_unreachable | term()}
  def select_initial_model(_desired, {:ok, []}), do: {:error, :no_models}

  def select_initial_model(desired, {:ok, [_ | _] = installed}) do
    if desired in installed, do: {:ok, desired}, else: {:fallback, hd(installed)}
  end

  def select_initial_model(_desired, {:error, reason}), do: {:error, reason}

  defp apply_default_base_url(opts, provider) do
    {provider_key, default_url} = provider_base_url_defaults(provider)

    case Application.get_env(:ex_athena, provider_key, [])[:base_url] do
      nil -> Keyword.put(opts, :base_url, default_url)
      _configured -> opts
    end
  end

  defp provider_base_url_defaults(:llamacpp), do: {:llamacpp, "http://localhost:8080"}
  defp provider_base_url_defaults(_), do: {:ollama, "http://localhost:11434"}
end

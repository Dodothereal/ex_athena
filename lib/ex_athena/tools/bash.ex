defmodule ExAthena.Tools.Bash do
  @moduledoc """
  Executes a shell command via `/bin/sh -c` with a configurable timeout.

  Arguments:

    * `command` (required) — the shell command.
    * `timeout_ms` (optional, default 120_000, max 600_000).

  Returns captured stdout+stderr plus the exit code. Timeouts kill the spawned
  process and surface `{:error, :timeout}` to the loop.

  Runs with `cd: ctx.cwd`, `stderr_to_stdout: true`. No input redirection.
  """

  @behaviour ExAthena.Tool

  @default_timeout 120_000
  @max_timeout 600_000

  # Patterns that mark a command as a write/destructive operation. Anything
  # NOT matching is treated as read-only. Used by `Permissions.check_phase/3`
  # to allow read-only bash invocations in :plan phase while still blocking
  # mutations.
  @write_patterns [
    ~r/\b(mkdir|touch|rm|mv|cp|chmod|chown)\b/,
    ~r/\bgit\s+(add|commit|push|merge|rebase|checkout|reset|clean|stash|branch\s+-[dD])\b/,
    ~r/\b(npm|yarn|pnpm|mix|bundle|pip|cargo)\s+(install|add|remove|update|new|init)\b/,
    ~r/\bmix\s+(ecto\.migrate|ecto\.create|ecto\.rollback|ecto\.gen\.migration|ash\.codegen|phx\.gen)\b/,
    ~r/[>|]\s*tee\b/,
    ~r/>>?\s/,
    ~r/\bsed\s+-i\b/,
    ~r/\bdd\b/,
    ~r/\btruncate\b/,
    ~r/\bcurl\b.*-[oO]\b/,
    ~r/\bwget\b/
  ]

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do: "Run a shell command in the working directory. Captures stdout+stderr and the exit code."

  @doc """
  Classify a bash invocation's `args` as read-only or not. Used by the
  permissions layer to allow read-only bash calls (cat, ls, grep, git log,
  gh issue view, …) during `:plan` phase while still denying mutations
  (rm, mkdir, redirects, git add/commit, mix ecto.migrate, …).

  Returns `true` when `args["command"]` does not match any known
  write/destructive pattern. Missing/empty command → `false` (treat as
  not read-only so the model gets a clear phase-gated denial rather than
  a silent allow).
  """
  @spec read_only_command?(map()) :: boolean()
  def read_only_command?(%{"command" => cmd}) when is_binary(cmd) and cmd != "" do
    trimmed = String.trim(cmd)
    not Enum.any?(@write_patterns, fn pattern -> Regex.match?(pattern, trimmed) end)
  end

  def read_only_command?(_), do: false

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string"},
        timeout_ms: %{type: "integer", description: "default 120_000, max 600_000"}
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, %{cwd: cwd}) when is_binary(command) do
    timeout =
      case Map.get(args, "timeout_ms") do
        t when is_integer(t) and t > 0 -> min(t, @max_timeout)
        _ -> @default_timeout
      end

    run(command, cwd, timeout)
  end

  def execute(_, _), do: {:error, :missing_command}

  defp run(command, cwd, timeout) do
    sh = System.find_executable("sh") || "/bin/sh"

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: cwd
      ])

    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + timeout
    collect(port, [], deadline, command, started_at)
  end

  defp collect(port, acc, deadline, command, started_at) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        kill(port)
        {:error, :timeout}

      true ->
        receive do
          {^port, {:data, data}} ->
            collect(port, [data | acc], deadline, command, started_at)

          {^port, {:exit_status, code}} ->
            body = acc |> Enum.reverse() |> IO.iodata_to_binary()
            duration_ms = System.monotonic_time(:millisecond) - started_at
            llm = "exit #{code}\n" <> body

            ui = %{
              kind: :process,
              payload: %{
                command: command,
                exit_code: code,
                stdout: body,
                duration_ms: duration_ms
              }
            }

            {:ok, llm, ui}
        after
          remaining ->
            kill(port)
            {:error, :timeout}
        end
    end
  end

  defp kill(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end

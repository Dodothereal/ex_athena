defmodule ExAthena.Tools.Bash do
  @moduledoc """
  Executes a shell command via `/bin/sh -c` with a configurable timeout.

  Arguments:

    * `command` (required) — the shell command.
    * `timeout_ms` (optional, default 120_000, max 600_000).

  Returns captured stdout+stderr plus the exit code. Timeouts kill the spawned
  process and surface `{:error, :timeout}` to the loop.

  Runs with `cd: ctx.cwd`, `stderr_to_stdout: true`. No input redirection.

  When the run is confined (`ctx.allowed_roots` is set), the command is wrapped
  in an OS sandbox (`ExAthena.Sandbox`) that blocks writes outside the roots. If
  no sandbox helper is available the command runs unconfined with a logged
  warning — never a fake command-string scan.
  """

  @behaviour ExAthena.Tool

  require Logger

  @default_timeout 120_000
  @max_timeout 600_000

  # Output cap: an uncapped `find .` dumped megabytes into a worker's
  # context (observed live: 204k input tokens by iteration 24 → starved to
  # error_max_turns). Head + tail survive; the cut is explicit so the model
  # narrows the command instead of assuming it saw everything.
  @max_output_chars 16_000
  @head_chars 12_000
  @tail_chars 4_000

  # Deny patterns — a first-pass backstop that marks a command as
  # write/destructive regardless of what the allowlist below would say.
  # Retained from the original (blocklist-only) classifier as
  # defense-in-depth; the actual read-only decision is allowlist-based
  # (see `read_only_command?/1`).
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

  # Commands whose plain invocation is read-only. The head of EVERY shell
  # segment (split on `;`, `&&`, `||`, `|`, `&`, newline) must appear here —
  # or be one of the subcommand-gated commands below (git/gh/mix/find/sort) —
  # for the whole invocation to classify read-only. Anything unknown
  # (including interpreters: python/perl/ruby/node/sh/ex/ed/…) is treated
  # as MUTATING: interpreters execute arbitrary code, so a blocklist can
  # never enumerate the write verbs.
  @readonly_commands ~w(
    cat tac ls dir grep egrep fgrep rg ag ack head tail wc file stat pwd
    tree du df basename dirname realpath readlink which type whereis
    whoami id groups date cal uptime uname hostname printenv echo printf
    uniq cut tr diff comm column nl od strings hexdump xxd less more
    man apropos jq yq ps lsof locale arch nproc sw_vers seq expr
    md5sum shasum sha256sum cksum true false test
  )

  # git subcommands that only inspect the repository. Deliberately excludes
  # branch/tag/stash/remote/config/worktree — their bare forms list, but
  # their argument forms create/delete, and telling those apart reliably
  # is not worth the risk in a read-only phase.
  @git_readonly_subcommands ~w(
    status log diff show blame grep shortlog describe rev-parse ls-files
    ls-tree ls-remote cat-file reflog help version var count-objects
  )

  # gh: `gh <group> <verb>` is read-only only for these verbs
  # (view/list/status/diff/checks); `gh api` can POST, so it is excluded.
  @gh_readonly_verbs ~w(view list status diff checks)

  # mix tasks that only read project state. Excludes compile/test — they
  # execute arbitrary project code and write _build.
  @mix_readonly_tasks ~w(help deps deps.tree app.tree xref hex.info hex.search hex.outdated)

  # find actions that mutate or execute — a `find` carrying any of these is
  # not read-only.
  @find_mutating_flags ~w(-delete -exec -execdir -ok -okdir -fprint -fprintf -fls)

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

  **Allowlist-based**: a command is read-only only when every shell segment
  (split on `;`, `&&`, `||`, `|`, `&`, newline) starts with a command known
  to be read-only. Unknown commands — including interpreter one-liners like
  `python -c`, `perl -e`, `ruby -e`, `node -e`, and editors like `ex`/`ed` —
  are treated as MUTATING, because arbitrary code execution can never be
  proven read-only by a string scan. Command substitution (`$(…)`, backticks)
  and file redirects (except `2>&1`-style fd duplication and `/dev/null`
  discards) also disqualify a command.

  Missing/empty command → `false` (treat as not read-only so the model gets
  a clear phase-gated denial rather than a silent allow).

  This classifier gates the `:plan` phase only; it is advisory next to the
  OS sandbox (`ExAthena.Sandbox`) which enforces write confinement for
  confined runs regardless of phase.
  """
  @spec read_only_command?(map()) :: boolean()
  def read_only_command?(%{"command" => cmd}) when is_binary(cmd) and cmd != "" do
    trimmed = String.trim(cmd)
    stripped = strip_quoted(trimmed)

    # Harmless redirect forms are erased before the redirect scan AND the
    # segment split (`2>&1` contains `&`, which would otherwise split into
    # a bogus `1` segment).
    normalized =
      stripped
      |> String.replace(~r{\d*>&\d+}, " ")
      |> String.replace(~r{\d*>>?\s*/dev/null}, " ")

    cond do
      # Command substitution can hide arbitrary writes inside a read-only
      # head (`cat $(rm -rf x)`), including inside double quotes.
      String.contains?(trimmed, "$(") or String.contains?(trimmed, "`") ->
        false

      # Backstop deny patterns (checked against the quote-stripped command so
      # quoted text — e.g. `grep "rm -rf" lib/` — doesn't false-positive).
      Enum.any?(@write_patterns, fn pattern -> Regex.match?(pattern, stripped) end) ->
        false

      # Any remaining `>` is a file redirect — a write.
      String.contains?(normalized, ">") ->
        false

      true ->
        case segments(normalized) do
          [] -> false
          segs -> Enum.all?(segs, &segment_read_only?/1)
        end
    end
  end

  def read_only_command?(_), do: false

  # Replace quoted spans with a placeholder so quoted metacharacters
  # (`grep -E "foo|bar"`) neither split segments nor trip deny patterns.
  # Unbalanced quotes leave text in place — conservative: it can only cause
  # a deny, never an allow.
  defp strip_quoted(cmd), do: Regex.replace(~r/"[^"]*"|'[^']*'/, cmd, "_")

  defp segments(cmd) do
    cmd
    |> String.split(~r/&&|\|\||[;|&\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp segment_read_only?(segment) do
    tokens =
      segment
      |> String.split(~r/\s+/, trim: true)
      # `FOO=bar cmd` — skip leading environment assignments.
      |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))

    case tokens do
      [] ->
        false

      [head | rest] ->
        case Path.basename(head) do
          "git" -> match?([sub | _] when sub in @git_readonly_subcommands, rest)
          "gh" -> gh_read_only?(rest)
          "mix" -> match?([task | _] when task in @mix_readonly_tasks, rest)
          "find" -> not Enum.any?(rest, &(&1 in @find_mutating_flags))
          "fd" -> not Enum.any?(rest, &(&1 in ["-x", "--exec", "-X", "--exec-batch"]))
          "sort" -> "-o" not in rest and "--output" not in rest
          base -> base in @readonly_commands
        end
    end
  end

  defp gh_read_only?(["status" | _]), do: true
  defp gh_read_only?(["auth", "status" | _]), do: true
  defp gh_read_only?(["search" | _]), do: true
  defp gh_read_only?([_group, verb | _]) when verb in @gh_readonly_verbs, do: true
  defp gh_read_only?(_), do: false

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
  def execute(%{"command" => command} = args, ctx) when is_binary(command) do
    timeout =
      case Map.get(args, "timeout_ms") do
        t when is_integer(t) and t > 0 -> min(t, @max_timeout)
        _ -> @default_timeout
      end

    run(command, ctx.cwd, timeout, Map.get(ctx, :allowed_roots))
  end

  def execute(_, _), do: {:error, :missing_command}

  # Unconfined: bare `sh -c`. Confined: wrap in an OS sandbox restricted to the
  # roots; if no sandbox helper exists, warn and run unconfined rather than fake
  # confinement with a bypassable command-string scan.
  defp run(command, cwd, timeout, roots) do
    {exe, args} = sandboxed_argv(command, cwd, roots)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: cwd
      ])

    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + timeout
    collect(port, [], deadline, command, started_at)
  end

  defp sandboxed_argv(command, _cwd, nil) do
    {System.find_executable("sh") || "/bin/sh", ["-c", command]}
  end

  defp sandboxed_argv(command, cwd, roots) do
    case ExAthena.Sandbox.wrap(command, roots, cwd) do
      {:ok, argv} ->
        argv

      {:unavailable, argv} ->
        Logger.warning(
          "[ExAthena.Bash] confinement requested but no OS sandbox " <>
            "(sandbox-exec/bwrap) is available — running the command UNCONFINED"
        )

        argv
    end
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
            body = acc |> Enum.reverse() |> IO.iodata_to_binary() |> cap_output()
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

  defp cap_output(body) when byte_size(body) <= @max_output_chars, do: body

  defp cap_output(body) do
    cut = byte_size(body) - @head_chars - @tail_chars

    head = binary_part(body, 0, @head_chars)
    tail = binary_part(body, byte_size(body) - @tail_chars, @tail_chars)

    head <>
      "\n…[truncated #{cut} chars — narrow the command (use head/grep/max_results)]…\n" <>
      tail
  end

  defp kill(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end

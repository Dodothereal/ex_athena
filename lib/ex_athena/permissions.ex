defmodule ExAthena.Permissions.Denial do
  @moduledoc """
  Structured permission-denial returned by `ExAthena.Permissions.check/3`.

  Returned inside `{:deny, %Denial{}}` so consumers can pattern-match on
  `denial.code` instead of grepping reason strings. The `String.Chars`
  implementation returns `reason`, so existing callers using
  `to_string/1` continue to work.

  ## Fields

    * `:reason` — human-readable message suitable for surfacing in tool-result
      content or logs.
    * `:code` — machine-readable cause (`:phase_gated | :budget_exceeded |
      :user_denied | :sandbox_violation | :unknown`).
    * `:metadata` — structured context (e.g. `requested_tool`,
      `allowed_tools`, `phase`); also carries any raw callback `:deny`
      reason under `metadata.raw`.
  """

  @type code :: :phase_gated | :budget_exceeded | :user_denied | :sandbox_violation | :unknown

  @enforce_keys [:reason, :code]
  defstruct [:reason, :code, metadata: %{}]

  @type t :: %__MODULE__{
          reason: String.t(),
          code: code(),
          metadata: map()
        }

  defimpl String.Chars do
    def to_string(%{reason: r}), do: r
  end
end

defmodule ExAthena.Permissions do
  @moduledoc """
  Decides whether a tool call is allowed.

  Every tool call runs through `check/4` before execution. The check combines
  four sources — in this order, first decisive wins:

    1. **`disallowed_tools`** — an explicit blocklist. Always denies.
    2. **`allowed_tools`** — an explicit allowlist. If non-nil, denies anything
       not in it.
    3. **`phase`** — the current permission mode:
       * `:plan` — read-only, deny-by-default. Only tools known to be
         read-only are allowed: the builtin read-only set, session-control
         tools (`todo_write` / `ask_user` / `finish` — they mutate only
         session bookkeeping), read-only bash commands, and custom/MCP
         tools that opted in (module `read_only?/0` callback, MCP
         `annotations.readOnlyHint`, or the `readonly_tools:` option).
         Everything else — including unknown tools — is denied. Exiting
         plan mode from a run the host pinned to `:plan` requires
         `can_use_tool` approval and is denied when no callback exists.
       * `:default` — read + write. `can_use_tool` callback (if supplied) can
         ask the user.
       * `:accept_edits` — auto-allow Read/Edit/Write/Glob/Grep/WebFetch
         + `plan_mode` / `spawn_agent`; still consults `can_use_tool` for
         everything else (e.g. `bash`, custom tools).
       * `:trusted` — skip the `can_use_tool` callback for every tool.
         Still respects the disallow / allowlist by default; pass
         `respect_denylist: false` to disable that too (equivalent to
         `:bypass_permissions`).
       * `:bypass_permissions` — everything allowed without asking.
    4. **`can_use_tool`** — caller-supplied callback (only in `:default`
       and unconditionally-allowed-tool slots of `:accept_edits`).

  The `can_use_tool` callback is a function `(tool_name, arguments, ctx ->
  :allow | :deny | {:deny, reason})` that the loop calls in `:default` mode
  for anything the caller marked as sensitive. See `Permissions.Opts` below.

  Reserved name: `:auto` is reserved for the future ML safety classifier
  mode the Claude Code paper describes; do not use it.

  ## Deny-first ordering

  The check chain is **disallowed → allowed → phase → callback**, with the
  first decisive answer winning. A blocked tool stays blocked even when
  `:bypass_permissions` would otherwise allow everything:

      iex> alias ExAthena.{Permissions, ToolContext}
      iex> alias ExAthena.Messages.ToolCall
      iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
      iex> ctx = ToolContext.new(cwd: "/tmp", phase: :bypass_permissions)
      iex> {:deny, denial} = Permissions.check(tc, ctx, %{disallowed_tools: ["bash"]})
      iex> denial.code
      :user_denied

  Likewise, an allowlist denies everything outside it even if a callback
  would have allowed:

      iex> alias ExAthena.{Permissions, ToolContext}
      iex> alias ExAthena.Messages.ToolCall
      iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
      iex> ctx = ToolContext.new(cwd: "/tmp", phase: :default)
      iex> opts = %{allowed_tools: ["read"], can_use_tool: fn _, _, _ -> :allow end}
      iex> {:deny, denial} = Permissions.check(tc, ctx, opts)
      iex> denial.code
      :user_denied
  """

  alias ExAthena.Messages.ToolCall
  alias ExAthena.Permissions.Denial
  alias ExAthena.ToolContext

  @readonly_tools ~w(read glob grep web_fetch web_search usage_rules plan_mode spawn_agent lsp)
  # `todo_write` is deliberately NOT here: it mutates session bookkeeping
  # (the todo list), never the workspace/filesystem, so it stays allowed in
  # the read-only `:plan` phase (see check_phase/4). Orchestrate planning and
  # read-only `explore` workers both need it to record their plan.
  #
  # Session-control tools: they interact with the host/session (asking the
  # user a question, ending the run), never the workspace — orchestrate's
  # planning turns need both, so they stay allowed in `:plan`.
  @session_tools ~w(todo_write ask_user finish)
  # `:accept_edits` auto-allows file edits + every read-only tool,
  # but still falls through to the callback for everything else
  # (bash, custom tools).
  @auto_allow_in_accept_edits ~w(read glob grep web_fetch web_search usage_rules plan_mode spawn_agent write edit todo_write)

  @type result ::
          :allow
          | {:deny, Denial.t()}
          | {:halt, term()}

  @type opts :: %{
          optional(:phase) => ToolContext.phase(),
          optional(:allowed_tools) => [String.t()] | nil,
          optional(:disallowed_tools) => [String.t()] | nil,
          optional(:readonly_tools) => [String.t()] | nil,
          optional(:can_use_tool) => (String.t(), map(), ToolContext.t() -> result()),
          optional(:respect_denylist) => boolean()
        }

  @doc """
  Check whether `tool_call` is allowed under `opts`. Returns `:allow`,
  `{:deny, %ExAthena.Permissions.Denial{}}`, or `{:halt, reason}` when the
  `can_use_tool` callback requests a hard stop.
  """
  @spec check(ToolCall.t(), ToolContext.t(), opts()) :: result()
  def check(%ToolCall{name: name, arguments: args}, %ToolContext{} = ctx, opts) do
    with :allow <- check_disallowed(name, ctx.phase, opts),
         :allow <- check_allowed(name, opts),
         :allow <- check_phase(name, args, ctx.phase, opts),
         :allow <- check_callback(name, args, ctx, ctx.phase, opts) do
      :allow
    end
  end

  # Deny-first ordering is preserved. The denylist always wins, including
  # in `:bypass_permissions` mode (the "absolutely never" list is the
  # user's explicit veto). The only escape hatch is `:trusted` with
  # `respect_denylist: false` — opt-in for very-trusted automation
  # contexts where the host is sure no per-tool denials should apply.
  defp check_disallowed(name, :trusted, opts) do
    if opts[:respect_denylist] == false do
      :allow
    else
      check_disallowed_list(name, opts)
    end
  end

  defp check_disallowed(name, _phase, opts), do: check_disallowed_list(name, opts)

  defp check_disallowed_list(name, opts) do
    case opts[:disallowed_tools] do
      nil ->
        :allow

      list when is_list(list) ->
        if name in list do
          {:deny,
           %Denial{
             code: :user_denied,
             reason: "tool \"#{name}\" is explicitly disallowed",
             metadata: %{requested_tool: name}
           }}
        else
          :allow
        end
    end
  end

  defp check_allowed(name, opts) do
    case opts[:allowed_tools] do
      nil ->
        :allow

      list when is_list(list) ->
        if name in list do
          :allow
        else
          {:deny,
           %Denial{
             code: :user_denied,
             reason: "tool \"#{name}\" is not in the allowed list",
             metadata: %{requested_tool: name, allowed_tools: list}
           }}
        end
    end
  end

  defp check_phase(name, args, :plan, opts) do
    cond do
      # Exiting plan mode is a privilege escalation when the HOST pinned the
      # run to :plan (`opts[:phase]`, the phase the run was configured with,
      # never mutated by transitions). It must never be the model's own
      # decision — see check_plan_mode/2.
      name == "plan_mode" ->
        check_plan_mode(args, opts)

      # Session bookkeeping / host interaction, not a workspace mutation —
      # safe in read-only investigation. Lets orchestrate planning + read-only
      # workers record their plan (todo_write), ask the user (ask_user), and
      # end the run (finish) without tripping the phase gate.
      name in @session_tools ->
        :allow

      name in @readonly_tools ->
        :allow

      # Opt-in registry: custom/MCP tools declared read-only (module
      # `read_only?/0` callback, MCP `annotations.readOnlyHint`, or the
      # host's `readonly_tools:` option). Assembled by the loop.
      name in List.wrap(opts[:readonly_tools]) ->
        :allow

      name == "bash" ->
        if ExAthena.Tools.Bash.read_only_command?(args) do
          :allow
        else
          {:deny,
           %Denial{
             code: :phase_gated,
             reason:
               "bash command is not recognized as read-only, so plan phase denies it " <>
                 "(unknown commands and interpreters are treated as mutating; " <>
                 "use read-only commands like cat/ls/grep/git log)",
             metadata: %{
               phase: :plan,
               requested_tool: "bash",
               allowed_tools: @readonly_tools ++ ["bash (read-only commands only)"]
             }
           }}
        end

      # Deny-by-default: anything not known read-only (unrecognized builtin,
      # MCP tool, host tool) is treated as mutating in the read-only phase.
      true ->
        {:deny,
         %Denial{
           code: :phase_gated,
           reason:
             "tool \"#{name}\" is not allowed in plan phase (plan phase denies every " <>
               "tool not known to be read-only; declare `read_only?/0` on the tool, " <>
               "set the MCP readOnlyHint annotation, or list it in `readonly_tools:`)",
           metadata: %{phase: :plan, requested_tool: name, allowed_tools: @readonly_tools}
         }}
    end
  end

  defp check_phase(_name, _args, :bypass_permissions, _opts), do: :allow
  defp check_phase(_name, _args, :trusted, _opts), do: :allow
  defp check_phase(_name, _args, :accept_edits, _opts), do: :allow
  defp check_phase(_name, _args, _, _opts), do: :allow

  # Gate the `:plan → :default` self-escalation. Three cases:
  #
  #   * The model entered plan itself (host configured a looser phase,
  #     `opts[:phase] != :plan`): exiting merely restores the host's original
  #     grant — allowed without ceremony (the callback, when configured, is
  #     still consulted downstream like for any tool).
  #   * Host pinned the run to :plan AND a `can_use_tool` callback exists:
  #     allow here so the normal callback step asks the host/user about the
  #     `plan_mode` exit call — approval happens exactly once, on the same
  #     path as every other sensitive tool.
  #   * Host pinned the run to :plan and NO callback exists: deny. The host
  #     explicitly confined the run to read-only and left no approval
  #     channel — silent self-escalation is precisely the bypass this blocks.
  #
  # `"enter"` (and anything that isn't an exit) is never an escalation.
  defp check_plan_mode(%{"action" => "exit"}, opts) do
    cond do
      opts[:phase] != :plan ->
        :allow

      is_function(opts[:can_use_tool], 3) ->
        :allow

      true ->
        {:deny,
         %Denial{
           code: :phase_gated,
           reason:
             "exiting plan mode requires host approval, and this run was started in " <>
               ":plan phase with no can_use_tool callback configured — finish your " <>
               "plan and report it; only the host can lift the read-only restriction",
           metadata: %{phase: :plan, requested_tool: "plan_mode", action: "exit"}
         }}
    end
  end

  defp check_plan_mode(_args, _opts), do: :allow

  # `:trusted`, `:bypass_permissions`, and the auto-allow set of
  # `:accept_edits` skip the callback. Everything else (default mode +
  # the non-auto-allow tools in accept_edits) consults it.
  defp check_callback(_name, _args, _ctx, :bypass_permissions, _opts), do: :allow
  defp check_callback(_name, _args, _ctx, :trusted, _opts), do: :allow

  defp check_callback(name, args, ctx, :accept_edits, opts) do
    if name in @auto_allow_in_accept_edits do
      :allow
    else
      do_callback(name, args, ctx, opts)
    end
  end

  defp check_callback(name, args, ctx, _phase, opts), do: do_callback(name, args, ctx, opts)

  defp do_callback(name, args, ctx, opts) do
    case opts[:can_use_tool] do
      nil -> :allow
      fun when is_function(fun, 3) -> normalize(fun.(name, args, ctx))
    end
  end

  defp normalize(:allow), do: :allow
  defp normalize({:allow, _}), do: :allow

  defp normalize(:deny),
    do: {:deny, %Denial{code: :user_denied, reason: "denied by callback", metadata: %{}}}

  defp normalize({:deny, %Denial{}} = result), do: result

  defp normalize({:deny, reason}),
    do: {:deny, %Denial{code: :user_denied, reason: inspect(reason), metadata: %{raw: reason}}}

  defp normalize(:halt), do: {:halt, :halt}
  defp normalize({:halt, _} = halt), do: halt

  defp normalize(other),
    do:
      {:deny,
       %Denial{
         code: :unknown,
         reason: "unexpected callback result: #{inspect(other)}",
         metadata: %{raw: other}
       }}

  # Permissiveness ranking used by `most_restrictive_phase/2`. Lower rank =
  # more restrictive. Unknown atoms rank as MOST permissive so they always
  # lose against any known phase — a typo'd phase in an agent definition can
  # then never widen a child's privileges past its parent.
  @phase_rank %{plan: 0, default: 1, accept_edits: 2, trusted: 3, bypass_permissions: 4}

  @doc """
  The more restrictive of two phases (`:plan` < `:default` < `:accept_edits`
  < `:trusted` < `:bypass_permissions`).

  Used by `ExAthena.Tools.SpawnAgent` to clamp a subagent's requested phase
  to its parent's — a child may narrow its phase but never widen it. An
  unrecognised phase atom is treated as maximally permissive, so it is
  always replaced by the other (known) phase.
  """
  @spec most_restrictive_phase(atom(), atom()) :: atom()
  def most_restrictive_phase(a, b) do
    if phase_rank(a) <= phase_rank(b), do: a, else: b
  end

  defp phase_rank(phase), do: Map.get(@phase_rank, phase, 99)

  @doc "Static list of read-only tool names the `:plan` phase permits."
  @spec readonly_tools() :: [String.t()]
  def readonly_tools, do: @readonly_tools

  @doc """
  Tools to advertise to the model during read-only planning/scope phases.
  Same as `readonly_tools/0` plus `"bash"`, which is conditionally allowed
  in `:plan` (read-only commands only — see `check_phase/4`).

  Hosts that build their plan-mode tool list from this stay in sync with
  the permissions layer automatically when ex_athena widens or narrows
  what's safe in plan phase.
  """
  @spec plan_mode_tools() :: [String.t()]
  def plan_mode_tools, do: @readonly_tools ++ ["bash"]

  @artifact_dirs ~w(_build/ deps/ node_modules/ .git/ priv/static/ tmp/)

  @doc """
  Path prefixes that `Glob`/`Grep` skip by default — build outputs and
  dependency caches that pollute the model's context without adding signal.

  Each entry ends in `/` so plain `String.starts_with?/2` matches a whole
  directory and never a same-named file at the root. Pass
  `include_artifacts: true` to either tool to bypass the filter.
  """
  @spec artifact_dirs() :: [String.t()]
  def artifact_dirs, do: @artifact_dirs
end

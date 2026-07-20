defmodule ExAthena.ToolContext do
  @moduledoc """
  Context handed to every tool execution.

  Carries the working directory the loop should treat as root, the current
  permission mode, the session id (if any), and a free-form `assigns` map for
  custom tools to stash arbitrary data the consumer needs (project id,
  conversation id, ticket id — whatever the host cares about).

  Tools that don't care about context can ignore it, but `cwd` and `phase`
  are load-bearing for any tool that touches the filesystem or checks
  permissions.
  """

  @enforce_keys [:cwd]
  defstruct cwd: nil,
            phase: :default,
            session_id: nil,
            tool_call_id: nil,
            allowed_roots: nil,
            assigns: %{}

  @type phase :: :plan | :default | :accept_edits | :trusted | :bypass_permissions

  @type t :: %__MODULE__{
          cwd: Path.t(),
          phase: phase(),
          session_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          # nil = unconfined (paths/bash/web are not boundary-checked). A list of
          # absolute directories = confined: filesystem tools may only touch
          # paths inside one of them, web tools refuse private/loopback hosts,
          # and bash runs under an OS sandbox restricted to these roots.
          allowed_roots: [Path.t()] | nil,
          assigns: map()
        }

  @doc "Build a context. `:cwd` is required; everything else defaults."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Whether this context confines tools to `allowed_roots`."
  @spec confined?(t()) :: boolean()
  def confined?(%__MODULE__{allowed_roots: roots}), do: is_list(roots)

  # Mirrors the kernel's nested-symlink limit (Linux SYMLOOP_MAX/ELOOP ≈ 40).
  # Exceeding it means a symlink loop (or absurd nesting) — treated as outside.
  @max_symlink_hops 40

  @doc """
  Whether an absolute `path` lies within one of `roots`. Compares on path
  segments (not string prefixes) so `/foo` never matches `/foobar`. A path equal
  to a root counts as inside it.

  Both `path` and `roots` are canonicalized first — every existing symlink
  component is resolved to its real target — so a symlink placed inside a root
  but pointing outside does not pass, while symlinks that stay inside the roots
  (and roots that are themselves symlinks, e.g. macOS `/tmp` →
  `/private/tmp`) keep working. Symlink loops count as outside.
  """
  @spec within_roots?(Path.t(), [Path.t()]) :: boolean()
  def within_roots?(path, roots) when is_list(roots) do
    case path |> Path.expand() |> canonicalize() do
      {:ok, canonical} ->
        path_parts = Path.split(canonical)

        Enum.any?(roots, fn root ->
          case root |> Path.expand() |> canonicalize() do
            {:ok, canonical_root} -> List.starts_with?(path_parts, Path.split(canonical_root))
            {:error, _} -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  # Resolve every symlink component of an already-expanded absolute path,
  # walking left to right the way the OS does. Components that don't exist yet
  # are kept lexically (files about to be created canonicalize through their
  # deepest existing ancestor). Relative link targets resolve against the
  # link's directory; a resolved target may itself contain symlinks, so the
  # walk restarts from its head. O(path components), bounded by the hop cap.
  defp canonicalize(abs_path) do
    case Path.split(abs_path) do
      [fs_root | components] -> do_canonicalize([fs_root], components, @max_symlink_hops)
      [] -> {:ok, abs_path}
    end
  end

  defp do_canonicalize(resolved, [], _hops), do: {:ok, Path.join(resolved)}

  defp do_canonicalize(resolved, [component | rest], hops) do
    candidate = Path.join(resolved ++ [component])

    case File.read_link(candidate) do
      {:ok, _target} when hops <= 0 ->
        {:error, :symlink_loop}

      {:ok, target} ->
        retarget = Path.expand(target, Path.join(resolved))
        [fs_root | components] = Path.split(retarget)
        do_canonicalize([fs_root], components ++ rest, hops - 1)

      {:error, _not_a_symlink_or_missing} ->
        do_canonicalize(resolved ++ [component], rest, hops)
    end
  end

  @doc """
  Resolve a user-supplied `path` against `ctx.cwd`.

  Unconfined (`allowed_roots: nil`, the default) keeps the historical behaviour:
  relative paths are expanded against `cwd`, `..` traversal is rejected, and
  absolute paths pass through untouched.

  Confined (`allowed_roots` is a list) expands the path to an absolute one
  (handling `..`/`~` lexically), resolves symlinks (see `within_roots?/2`), and
  requires the canonical result to fall inside one of the roots, returning
  `{:error, {:path_outside_roots, abs}}` otherwise — so neither `/etc/passwd`,
  `../../secret`, nor an in-root symlink pointing outside can escape.
  """
  @spec resolve_path(t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve_path(%__MODULE__{} = ctx, path) when is_binary(path) do
    cond do
      String.contains?(path, "\0") -> {:error, :null_byte_in_path}
      is_list(ctx.allowed_roots) -> resolve_confined(ctx.cwd, ctx.allowed_roots, path)
      true -> resolve_unconfined(ctx.cwd, path)
    end
  end

  def resolve_path(_, _), do: {:error, :invalid_path}

  defp resolve_unconfined(cwd, path) do
    cond do
      Path.type(path) == :absolute -> {:ok, path}
      String.contains?(path, "..") -> {:error, :path_traversal_rejected}
      true -> {:ok, Path.expand(path, cwd)}
    end
  end

  defp resolve_confined(cwd, roots, path) do
    abs = if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, cwd)

    if within_roots?(abs, roots),
      do: {:ok, abs},
      else: {:error, {:path_outside_roots, abs}}
  end
end

defmodule ExAthena.Sandbox do
  @moduledoc """
  OS-level command confinement for the Bash tool.

  When a run is confined (`ExAthena.ToolContext.allowed_roots` is set), shell
  commands are wrapped so they cannot write outside the roots:

    * **macOS** — `sandbox-exec` with a generated SBPL profile that allows reads,
      exec and network but denies all writes except under the roots and the OS
      temp dir.
    * **Linux** — `bwrap` (bubblewrap): the whole filesystem mounted read-only,
      the roots and the temp dir bind-mounted read-write.

  Reads and network stay open — that's the FS write boundary, not a full jail
  (network egress is handled separately by the web tools' SSRF guard). The OS
  temp dir stays writable so ordinary toolchains (compilers, `mktemp`) work.

  Where no sandbox helper is available the command is returned **unwrapped** and
  the caller is expected to warn: we never fake confinement with a command-string
  scan (trivially bypassed via subshells/`eval`), so it's real-sandbox-or-nothing.
  """

  require Logger

  @doc """
  Build the argv to run `command` confined to `roots` with working dir `cwd`.

  Returns `{:ok, {executable, args}}` when an OS sandbox is available, or
  `{:unavailable, {executable, args}}` (the bare `sh -c command`) otherwise.
  """
  @spec wrap(String.t(), [Path.t()], Path.t()) ::
          {:ok, {String.t(), [String.t()]}} | {:unavailable, {String.t(), [String.t()]}}
  def wrap(command, roots, cwd) when is_binary(command) and is_list(roots) do
    sh = System.find_executable("sh") || "/bin/sh"
    roots = Enum.map(roots, &Path.expand/1)

    case backend() do
      {:macos, exe} ->
        {:ok, {exe, ["-p", macos_profile(roots), sh, "-c", command]}}

      {:linux, exe} ->
        {:ok, {exe, bwrap_args(roots, cwd) ++ [sh, "-c", command]}}

      :none ->
        {:unavailable, {sh, ["-c", command]}}
    end
  end

  @doc "Whether an OS sandbox helper is available on this host."
  @spec available?() :: boolean()
  def available?, do: backend() != :none

  # ── platform detection ──

  defp backend do
    case :os.type() do
      {:unix, :darwin} -> with exe when is_binary(exe) <- find("sandbox-exec"), do: {:macos, exe}
      {:unix, _} -> with exe when is_binary(exe) <- find("bwrap"), do: {:linux, exe}
      _ -> :none
    end
  end

  defp find(bin), do: System.find_executable(bin) || :none

  # ── macOS: SBPL profile (pure) ──

  @doc false
  @spec macos_profile([Path.t()]) :: String.t()
  def macos_profile(roots) do
    writable =
      (roots ++ ["/private/tmp", "/private/var/folders", "/private/var/tmp", "/dev"])
      |> Enum.map(&~s|  (subpath "#{escape(&1)}")|)
      |> Enum.join("\n")

    """
    (version 1)
    (allow default)
    (deny file-write*)
    (allow file-write*
    #{writable})
    """
  end

  # SBPL string literals are double-quoted; escape backslashes and quotes.
  defp escape(path), do: path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  # ── Linux: bwrap args (pure) ──

  @doc false
  @spec bwrap_args([Path.t()], Path.t()) :: [String.t()]
  def bwrap_args(roots, cwd) do
    binds = Enum.flat_map(roots, fn r -> ["--bind", r, r] end)

    ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", "/tmp", "/tmp"] ++
      binds ++ ["--chdir", cwd, "--"]
  end
end

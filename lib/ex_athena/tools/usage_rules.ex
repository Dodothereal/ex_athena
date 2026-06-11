defmodule ExAthena.Tools.UsageRules do
  @moduledoc """
  Read dependency **usage rules** — the LLM-oriented `usage-rules.md` docs that
  Elixir libraries ship in their Hex package (the `usage_rules` convention).

  These live locally in the project's deps:

    * `deps/<pkg>/usage-rules.md`            → addressed as `<pkg>`
    * `deps/<pkg>/usage-rules/<topic>.md`    → addressed as `<pkg>:<topic>`

  Prefer this over `web_fetch` of hexdocs: it's local, fast, version-accurate
  for exactly the deps in this project, and can't time out on a slow network.

    * No `package` arg → lists every available rule set in the project's deps.
    * `package: "ash"` → returns `deps/ash/usage-rules.md`.
    * `package: "phoenix:html"` → returns `deps/phoenix/usage-rules/html.md`.
  """

  @behaviour ExAthena.Tool

  @max_chars 20_000

  @impl true
  def name, do: "usage_rules"

  @impl true
  def description,
    do:
      "Read a dependency's usage rules — local LLM-oriented docs Elixir libs ship " <>
        "at deps/<pkg>/usage-rules.md. Call with no args to list available packages, " <>
        "or package: \"<pkg>\" (or \"<pkg>:<topic>\") to read one. Prefer this over " <>
        "web_fetch of hexdocs."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        package: %{
          type: "string",
          description:
            "Package name (e.g. \"ash\") or \"<pkg>:<topic>\" (e.g. \"phoenix:html\"). Omit to list all available rule sets."
        }
      },
      required: []
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(args, ctx) do
    deps = Path.join(ctx.cwd || File.cwd!(), "deps")

    case Map.get(args, "package") do
      pkg when is_binary(pkg) and pkg != "" -> read(deps, pkg)
      _ -> {:ok, list(deps)}
    end
  end

  defp list(deps) do
    case available_rules(deps) do
      [] ->
        "No usage rules found under #{deps}. " <>
          "(No dependency ships usage-rules.md, or deps aren't fetched.)"

      available ->
        "Available usage rules (call usage_rules with package: \"<name>\"):\n" <>
          Enum.map_join(available, "\n", &("- " <> &1))
    end
  end

  defp read(deps, pkg) do
    with {:ok, path} <- path_for(deps, pkg),
         {:ok, content} <- File.read(path) do
      {:ok, "# usage rules: #{pkg}\n\n" <> truncate(content)}
    else
      :error ->
        {:error, "invalid package name #{inspect(pkg)}"}

      {:error, _} ->
        {:error,
         "no usage rules for #{inspect(pkg)} — run usage_rules with no args to list what's available"}
    end
  end

  # `<pkg>` → deps/<pkg>/usage-rules.md; `<pkg>:<topic>` → nested topic file.
  # Names are validated to plain package/topic tokens so a model-supplied value
  # can never traverse outside the deps tree.
  defp path_for(deps, pkg) do
    case String.split(pkg, ":", parts: 2) do
      [base] ->
        if safe_name?(base),
          do: {:ok, Path.join([deps, base, "usage-rules.md"])},
          else: :error

      [base, topic] ->
        if safe_name?(base) and safe_name?(topic),
          do: {:ok, Path.join([deps, base, "usage-rules", topic <> ".md"])},
          else: :error
    end
  end

  defp safe_name?(name), do: name =~ ~r/^[A-Za-z0-9_-]+$/

  defp available_rules(deps) do
    main =
      deps
      |> Path.join("*/usage-rules.md")
      |> Path.wildcard()
      |> Enum.map(fn p -> p |> Path.dirname() |> Path.basename() end)

    nested =
      deps
      |> Path.join("*/usage-rules/*.md")
      |> Path.wildcard()
      |> Enum.map(fn p ->
        topic = Path.basename(p, ".md")
        pkg = p |> Path.dirname() |> Path.dirname() |> Path.basename()
        "#{pkg}:#{topic}"
      end)

    (main ++ nested) |> Enum.sort()
  end

  defp truncate(content) do
    if String.length(content) > @max_chars do
      String.slice(content, 0, @max_chars) <>
        "\n\n[...truncated — read the full deps/.../usage-rules.md for the rest]"
    else
      content
    end
  end
end

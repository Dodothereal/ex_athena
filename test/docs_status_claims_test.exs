defmodule ExAthena.DocsStatusClaimsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards against the failure mode of issue #129: shipped capabilities described
  in published docs as belonging to a future "Phase N".

  ex_athena is read by coding agents that follow "read the docs before coding",
  so a stale "ships in Phase 2" does not merely age badly — it makes consumers
  re-implement a capability that already exists.

  The patterns below are deliberately narrow: they match roadmap framing
  ("in Phase 2", "(Phase 2)", "Phase 1 surface") and not the ordinary English
  use of the word, so prose and prompt examples that legitimately say
  "Phase 1: read the files" stay legal.
  """

  # Roadmap framing only — see the moduledoc.
  @patterns [
    ~r/\bin Phase \d\b/i,
    ~r/\(Phase \d\)/i,
    ~r/\bPhase \d \(/i,
    ~r/\bPhase \d (surface|ships?|shipping|will|lands?)\b/i
  ]

  @roots ["README.md", "lib", "guides"]

  test "published docs make no 'Phase N' roadmap claims" do
    offenders =
      @roots
      |> Enum.flat_map(&files/1)
      |> Enum.flat_map(&offending_lines/1)

    assert offenders == [],
           """
           Roadmap-style status claims found in published docs.

           Every "Phase N" milestone in this project has shipped. If you are
           describing current behaviour, name the module (`ExAthena.Loop`)
           instead of the phase that delivered it.

           #{Enum.map_join(offenders, "\n", fn {file, line_no, line} -> "  #{file}:#{line_no}: #{String.trim(line)}" end)}
           """
  end

  defp files(root) do
    if File.dir?(root) do
      Path.wildcard(Path.join(root, "**/*.{ex,exs,md}"))
    else
      [root]
    end
  end

  defp offending_lines(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Enum.any?(@patterns, &Regex.match?(&1, line)) end)
    |> Enum.map(fn {line, line_no} -> {file, line_no, line} end)
  end
end

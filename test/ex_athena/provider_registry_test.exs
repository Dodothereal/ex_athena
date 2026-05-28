defmodule ExAthena.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias ExAthena.{ProviderRegistry, ProviderSpec}

  # ── Helpers ───────────────────────────────────────────────────────

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "ex_athena_reg_#{System.unique_integer([:positive])}")
  end

  defp tmp_dir_create do
    dir = tmp_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_json(dir, filename, data) do
    File.write!(Path.join(dir, filename), Jason.encode!(data))
  end

  defp start_registry(opts) do
    start_supervised!({ProviderRegistry, opts})
  end

  # ── Tests: empty / missing directory ──────────────────────────────

  describe "with empty or missing directory" do
    test "starts successfully when directory does not exist" do
      dir = tmp_dir()
      start_registry(providers_dir: dir)
      assert ProviderRegistry.list() == []
    end

    test "returns empty list when directory exists but is empty" do
      dir = tmp_dir_create()
      start_registry(providers_dir: dir)
      assert ProviderRegistry.list() == []
    end
  end

  # ── Tests: loading valid specs ─────────────────────────────────────

  describe "loading valid specs" do
    test "loads a single valid JSON file" do
      dir = tmp_dir_create()
      write_json(dir, "prov.json", %{name: "my-ollama", adapter: "req_llm"})
      start_registry(providers_dir: dir)

      assert [spec] = ProviderRegistry.list()
      assert spec.name == "my-ollama"
      assert spec.module == ExAthena.Providers.ReqLLM
    end

    test "loads optional fields from JSON" do
      dir = tmp_dir_create()

      write_json(dir, "prov.json", %{
        name: "custom",
        adapter: "req_llm",
        req_llm_provider_tag: "openai",
        base_url: "http://localhost:11434/v1",
        default_model: "llama3"
      })

      start_registry(providers_dir: dir)

      assert [spec] = ProviderRegistry.list()
      assert spec.req_llm_provider_tag == "openai"
      assert spec.base_url == "http://localhost:11434/v1"
      assert spec.default_model == "llama3"
    end

    test "loads multiple valid JSON files" do
      dir = tmp_dir_create()
      write_json(dir, "a.json", %{name: "prov-a", adapter: "req_llm"})
      write_json(dir, "b.json", %{name: "prov-b", adapter: "mock"})
      start_registry(providers_dir: dir)

      names = ProviderRegistry.list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["prov-a", "prov-b"]
    end

    test "lookup/1 returns spec by string name" do
      dir = tmp_dir_create()
      write_json(dir, "x.json", %{name: "my-provider", adapter: "mock"})
      start_registry(providers_dir: dir)

      assert {:ok, %ProviderSpec{name: "my-provider"}} = ProviderRegistry.lookup("my-provider")
    end

    test "lookup/1 returns spec by atom name" do
      dir = tmp_dir_create()
      write_json(dir, "x.json", %{name: "my-provider", adapter: "mock"})
      start_registry(providers_dir: dir)

      assert {:ok, %ProviderSpec{}} = ProviderRegistry.lookup(:"my-provider")
    end

    test "lookup/1 returns :error for unknown name" do
      dir = tmp_dir_create()
      start_registry(providers_dir: dir)

      assert :error = ProviderRegistry.lookup("nonexistent")
    end
  end

  # ── Tests: validation and skip-and-log on failure ─────────────────

  describe "validation on load — skip-and-log" do
    test "skips files with missing required name field" do
      dir = tmp_dir_create()
      write_json(dir, "bad.json", %{adapter: "req_llm"})
      start_registry(providers_dir: dir)

      assert ProviderRegistry.list() == []
    end

    test "skips files with missing required adapter field" do
      dir = tmp_dir_create()
      write_json(dir, "bad.json", %{name: "no-adapter"})
      start_registry(providers_dir: dir)

      assert ProviderRegistry.list() == []
    end

    test "skips files with unknown adapter" do
      dir = tmp_dir_create()
      write_json(dir, "bad.json", %{name: "x", adapter: "not_real"})
      start_registry(providers_dir: dir)

      assert ProviderRegistry.list() == []
    end

    test "skips malformed JSON files" do
      dir = tmp_dir_create()
      File.write!(Path.join(dir, "bad.json"), "not valid json {{{")
      start_registry(providers_dir: dir)

      assert ProviderRegistry.list() == []
    end

    test "skips invalid files but loads valid ones in the same directory" do
      dir = tmp_dir_create()
      write_json(dir, "good.json", %{name: "good", adapter: "mock"})
      write_json(dir, "bad.json", %{name: "bad"})
      start_registry(providers_dir: dir)

      assert [spec] = ProviderRegistry.list()
      assert spec.name == "good"
    end

    test "ignores non-JSON files" do
      dir = tmp_dir_create()
      File.write!(Path.join(dir, "readme.txt"), "not a spec")
      File.write!(Path.join(dir, "notes.md"), "# notes")
      start_registry(providers_dir: dir)

      assert ProviderRegistry.list() == []
    end
  end
end

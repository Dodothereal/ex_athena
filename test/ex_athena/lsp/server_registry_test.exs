defmodule ExAthena.Lsp.ServerRegistryTest do
  use ExUnit.Case, async: true

  alias ExAthena.Lsp.ServerRegistry

  describe "language_for_path/1" do
    test "detects elixir from .ex" do
      assert ServerRegistry.language_for_path("lib/foo.ex") == :elixir
    end

    test "detects elixir from .exs" do
      assert ServerRegistry.language_for_path("mix.exs") == :elixir
    end

    test "detects python from .py" do
      assert ServerRegistry.language_for_path("app/main.py") == :python
    end

    test "detects python from .pyi" do
      assert ServerRegistry.language_for_path("stubs/foo.pyi") == :python
    end

    test "detects rust from .rs" do
      assert ServerRegistry.language_for_path("src/main.rs") == :rust
    end

    test "detects go from .go" do
      assert ServerRegistry.language_for_path("cmd/main.go") == :go
    end

    test "detects typescript from .ts" do
      assert ServerRegistry.language_for_path("src/index.ts") == :typescript
    end

    test "detects typescript from .tsx" do
      assert ServerRegistry.language_for_path("src/App.tsx") == :typescript
    end

    test "detects typescript from .js" do
      assert ServerRegistry.language_for_path("app.js") == :typescript
    end

    test "detects typescript from .jsx" do
      assert ServerRegistry.language_for_path("App.jsx") == :typescript
    end

    test "detects typescript from .mjs" do
      assert ServerRegistry.language_for_path("index.mjs") == :typescript
    end

    test "detects typescript from .cjs" do
      assert ServerRegistry.language_for_path("index.cjs") == :typescript
    end

    test "returns nil for unknown extension" do
      assert ServerRegistry.language_for_path("README.md") == nil
    end

    test "returns nil for file with no extension" do
      assert ServerRegistry.language_for_path("Makefile") == nil
    end
  end

  describe "spawn_spec/1" do
    test "returns error for unsupported language" do
      assert {:error, :unsupported} = ServerRegistry.spawn_spec(:cobol)
    end

    test "returns error when binary is missing from PATH" do
      finder = fn _name -> nil end
      assert {:error, :unsupported} = ServerRegistry.spawn_spec(:elixir, finder)
    end

    test "returns spec for expert (default elixir server) with --stdio arg" do
      finder = fn
        "expert" -> "/usr/local/bin/expert"
        _ -> nil
      end

      assert {:ok, %{binary: "/usr/local/bin/expert", args: ["--stdio"]}} =
               ServerRegistry.spawn_spec(:elixir, finder)
    end

    test "elixir falls back to elixir-ls when expert is not on PATH" do
      finder = fn
        "expert" -> nil
        "elixir-ls" -> "/usr/local/bin/elixir-ls"
      end

      assert {:ok, %{binary: "/usr/local/bin/elixir-ls", args: []}} =
               ServerRegistry.spawn_spec(:elixir, finder)
    end

    test "elixir prefers expert over elixir-ls when both are present" do
      finder = fn
        "expert" -> "/usr/local/bin/expert"
        "elixir-ls" -> "/usr/local/bin/elixir-ls"
      end

      assert {:ok, %{binary: "/usr/local/bin/expert", args: ["--stdio"]}} =
               ServerRegistry.spawn_spec(:elixir, finder)
    end

    test "returns spec for pyright with --stdio arg" do
      finder = fn "pyright-langserver" -> "/usr/bin/pyright-langserver" end

      assert {:ok, %{binary: "/usr/bin/pyright-langserver", args: ["--stdio"]}} =
               ServerRegistry.spawn_spec(:python, finder)
    end

    test "returns spec for gopls with serve arg" do
      finder = fn "gopls" -> "/usr/local/bin/gopls" end

      assert {:ok, %{binary: "/usr/local/bin/gopls", args: ["serve"]}} =
               ServerRegistry.spawn_spec(:go, finder)
    end

    test "app-env override replaces default for a known language" do
      override = %{elixir: %{binary: "/custom/elixir-ls", args: ["--custom"]}}
      Application.put_env(:ex_athena, :lsp_servers, override)

      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_servers) end)

      finder = fn _name -> nil end

      assert {:ok, %{binary: "/custom/elixir-ls", args: ["--custom"]}} =
               ServerRegistry.spawn_spec(:elixir, finder)
    end

    test "app-env override with string key binary does not run through find_executable" do
      override = %{rust: %{binary: "/custom/rust-analyzer", args: []}}
      Application.put_env(:ex_athena, :lsp_servers, override)
      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_servers) end)

      finder = fn _name -> nil end

      assert {:ok, %{binary: "/custom/rust-analyzer", args: []}} =
               ServerRegistry.spawn_spec(:rust, finder)
    end
  end
end

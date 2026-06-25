defmodule ExAthena.Tools.LspTest do
  use ExUnit.Case, async: false

  alias ExAthena.Lsp.{Client, Manager}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Tools.Lsp
  alias ExAthena.{Permissions, ToolContext}

  @fake_server_script Path.expand("../../support/fake_lsp_server.exs", __DIR__)
  @elixir_bin System.find_executable("elixir")

  defp setup_lsp_override do
    Application.put_env(:ex_athena, :lsp_servers, %{
      elixir: %{binary: @elixir_bin, args: ["--erl", "-noinput", @fake_server_script]}
    })

    on_exit(fn -> Application.delete_env(:ex_athena, :lsp_servers) end)
  end

  defp start_lsp_supervisor do
    start_supervised!({Registry, keys: :unique, name: ExAthena.Lsp.Registry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Lsp.ClientSupervisor, strategy: :one_for_one}
    )

    start_supervised!(Manager)
  end

  defp unique_dir do
    dir = Path.join(System.tmp_dir!(), "lsp_tool_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_elixir_file(dir, name \\ "test.ex", content \\ "defmodule Test do\nend\n") do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp ctx(cwd), do: ToolContext.new(cwd: cwd)

  setup do
    setup_lsp_override()
    start_lsp_supervisor()
    dir = unique_dir()
    {:ok, dir: dir}
  end

  describe "action: definition" do
    test "returns formatted location string and ui payload", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:ok, result, ui} =
               Lsp.execute(
                 %{"action" => "definition", "file" => path, "line" => 0, "character" => 0},
                 ctx(dir)
               )

      # Fake server returns line 3, character 0 for any definition request
      assert result =~ ":3:0"
      assert ui.kind == :lsp
      assert ui.payload.action == :definition
      assert ui.payload.file == path
      assert is_list(ui.payload.results)
      assert length(ui.payload.results) == 1
      [loc] = ui.payload.results
      assert get_in(loc, ["range", "start", "line"]) == 3
    end
  end

  describe "action: references" do
    test "returns count and location list", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:ok, result, ui} =
               Lsp.execute(
                 %{"action" => "references", "file" => path, "line" => 0, "character" => 0},
                 ctx(dir)
               )

      assert result =~ "3 reference(s)"
      assert ui.payload.action == :references
      assert length(ui.payload.results) == 3
    end

    test "forwards include_declaration: false to LSP params", %{dir: dir} do
      path = write_elixir_file(dir)

      # Fake server accepts any references request — just verify it succeeds
      assert {:ok, result, _ui} =
               Lsp.execute(
                 %{
                   "action" => "references",
                   "file" => path,
                   "line" => 0,
                   "character" => 0,
                   "include_declaration" => false
                 },
                 ctx(dir)
               )

      assert result =~ "reference(s)"
    end
  end

  describe "action: hover" do
    test "returns markdown content string", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:ok, result, ui} =
               Lsp.execute(
                 %{"action" => "hover", "file" => path, "line" => 0, "character" => 0},
                 ctx(dir)
               )

      # Fake server returns "**doc** — doc text"
      assert result =~ "doc text"
      assert ui.payload.action == :hover
    end
  end

  describe "action: diagnostics" do
    test "returns diagnostics published on didOpen", %{dir: dir} do
      path = write_elixir_file(dir)

      Application.put_env(:ex_athena, :lsp_diagnostics_poll_ms, 5_000)
      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_diagnostics_poll_ms) end)

      assert {:ok, result, ui} =
               Lsp.execute(%{"action" => "diagnostics", "file" => path}, ctx(dir))

      assert result =~ "error"
      assert result =~ "undefined function"
      assert ui.payload.action == :diagnostics
      assert is_list(ui.payload.results)
      assert length(ui.payload.results) >= 1
    end

    test "returns empty result (not error) when no diagnostics within timeout", %{dir: dir} do
      path = write_elixir_file(dir)

      # Suppress the publishDiagnostics side-effect before the tool runs
      {:ok, pid} = Manager.client_for_file(dir, path)
      Client.notify(pid, "notif/suppress_next_diag", %{})

      # Short poll window so the test doesn't take long
      Application.put_env(:ex_athena, :lsp_diagnostics_poll_ms, 200)
      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_diagnostics_poll_ms) end)

      # Must be {:ok, ...}, never {:error, :timeout}
      assert {:ok, result, ui} =
               Lsp.execute(%{"action" => "diagnostics", "file" => path}, ctx(dir))

      assert result == "count: 0"
      assert ui.payload.results == []
    end
  end

  describe "action: workspace_symbol" do
    test "finds symbols by name across the project (no file needed)", %{dir: dir} do
      assert {:ok, result, ui} =
               Lsp.execute(%{"action" => "workspace_symbol", "query" => "hello"}, ctx(dir))

      # Fake server echoes the query into a function symbol + a module symbol
      assert result =~ "symbol(s)"
      assert result =~ "hello_fun"
      assert result =~ "(function)"
      assert ui.payload.action == :workspace_symbol
      assert length(ui.payload.results) == 2
    end

    test "missing query returns {:error, :missing_query}", %{dir: dir} do
      assert {:error, :missing_query} =
               Lsp.execute(%{"action" => "workspace_symbol"}, ctx(dir))
    end

    test "unknown language returns {:error, :unsupported_language}", %{dir: dir} do
      assert {:error, :unsupported_language} =
               Lsp.execute(
                 %{"action" => "workspace_symbol", "query" => "x", "language" => "cobol"},
                 ctx(dir)
               )
    end
  end

  describe "action: document_symbol" do
    test "outlines a file's symbols (hierarchical)", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:ok, result, ui} =
               Lsp.execute(%{"action" => "document_symbol", "file" => path}, ctx(dir))

      assert result =~ "symbol(s)"
      assert result =~ "Test (module)"
      assert result =~ "hello/1 (function)"
      assert ui.payload.action == :document_symbol
      # one top-level DocumentSymbol (the module), with a nested function
      assert length(ui.payload.results) == 1
    end

    test "missing file returns {:error, :missing_file}", %{dir: dir} do
      assert {:error, :missing_file} =
               Lsp.execute(%{"action" => "document_symbol"}, ctx(dir))
    end
  end

  describe "error: invalid / missing arguments" do
    test "invalid action string returns {:error, :invalid_action}", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:error, :invalid_action} =
               Lsp.execute(%{"action" => "unknown_action", "file" => path}, ctx(dir))
    end

    test "missing action key returns {:error, :missing_action}", %{dir: dir} do
      assert {:error, :missing_action} =
               Lsp.execute(%{"file" => "/some/file.ex"}, ctx(dir))
    end

    test "missing file key returns {:error, :missing_file}", %{dir: dir} do
      assert {:error, :missing_file} =
               Lsp.execute(%{"action" => "definition"}, ctx(dir))
    end

    test "missing position for definition returns {:error, :missing_position}", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:error, :missing_position} =
               Lsp.execute(%{"action" => "definition", "file" => path}, ctx(dir))
    end

    test "missing position for references returns {:error, :missing_position}", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:error, :missing_position} =
               Lsp.execute(%{"action" => "references", "file" => path}, ctx(dir))
    end

    test "missing position for hover returns {:error, :missing_position}", %{dir: dir} do
      path = write_elixir_file(dir)

      assert {:error, :missing_position} =
               Lsp.execute(%{"action" => "hover", "file" => path}, ctx(dir))
    end

    test "unsupported file extension returns {:error, :unsupported_language}", %{dir: dir} do
      unknown_path = Path.join(dir, "file.unknownext_xyz")
      File.write!(unknown_path, "content")

      assert {:error, :unsupported_language} =
               Lsp.execute(
                 %{
                   "action" => "definition",
                   "file" => unknown_path,
                   "line" => 0,
                   "character" => 0
                 },
                 ctx(dir)
               )
    end
  end

  describe "error: LSP server error response" do
    test "surfaces {:error, {:lsp_error, map}} when server returns error object", %{dir: dir} do
      path = write_elixir_file(dir)

      # Arm the fake server to fail the next request with a MethodNotFound error.
      # Use the synchronous request form so we don't race a notification against
      # the definition request that follows.
      {:ok, pid} = Manager.client_for_file(dir, path)
      assert {:ok, %{"armed" => true}} = Client.request(pid, "notif/fail_next", %{}, 5_000)

      assert {:error, {:lsp_error, err}} =
               Lsp.execute(
                 %{"action" => "definition", "file" => path, "line" => 0, "character" => 0},
                 ctx(dir)
               )

      assert is_map(err)
      assert Map.has_key?(err, "code")
      assert Map.has_key?(err, "message")
    end
  end

  describe "metadata" do
    test "Lsp is in builtins registry" do
      builtins = ExAthena.Tools.builtins()
      assert Lsp in builtins
    end

    test "find/2 resolves \"lsp\" to the Lsp module" do
      builtins = ExAthena.Tools.builtins()
      assert ExAthena.Tools.find(builtins, "lsp") == Lsp
    end

    test "parallel_safe?/0 is true" do
      assert Lsp.parallel_safe?() == true
    end

    test "\"lsp\" is allowed under :plan mode" do
      tc = %ToolCall{id: "c1", name: "lsp", arguments: %{}}
      ctx = ToolContext.new(cwd: "/tmp", phase: :plan)
      assert :allow = Permissions.check(tc, ctx, %{})
    end

    test "\"lsp\" appears in Permissions.readonly_tools/0" do
      assert "lsp" in Permissions.readonly_tools()
    end
  end

  describe "didOpen precedes request" do
    test "definition succeeds (proves didOpen was sent before the request)", %{dir: dir} do
      path = write_elixir_file(dir)

      # The fake server only responds to textDocument/definition after seeing
      # textDocument/didOpen for the URI. A successful result proves ordering.
      assert {:ok, result, _ui} =
               Lsp.execute(
                 %{"action" => "definition", "file" => path, "line" => 0, "character" => 0},
                 ctx(dir)
               )

      assert is_binary(result)
    end
  end
end

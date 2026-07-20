defmodule ExAthena.Tool.SpecTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tool.Spec

  defmodule FakeModTool do
    @behaviour ExAthena.Tool

    @impl true
    def name, do: "fake_mod"

    @impl true
    def description, do: "A fake module tool"

    @impl true
    def schema, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(%{"echo" => v}, _ctx), do: {:ok, v}

    @impl true
    def parallel_safe?, do: true
  end

  defmodule FakeModToolNoParallel do
    @behaviour ExAthena.Tool

    @impl true
    def name, do: "fake_mod_mut"

    @impl true
    def description, do: "A mutating fake module tool"

    @impl true
    def schema, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_args, _ctx), do: {:ok, "done"}
  end

  defmodule ReadOnlyModTool do
    @behaviour ExAthena.Tool

    @impl true
    def name, do: "fake_read_only"

    @impl true
    def description, do: "A read-only fake tool"

    @impl true
    def schema, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_args, _ctx), do: {:ok, "data"}

    @impl true
    def read_only?, do: true
  end

  describe "read_only? flag" do
    test "from_module reads the optional read_only?/0 callback" do
      assert Spec.from_module(ReadOnlyModTool).read_only? == true
    end

    test "from_module defaults read_only? to false when not implemented" do
      assert Spec.from_module(FakeModTool).read_only? == false
    end

    test "from_mcp honours the MCP readOnlyHint annotation" do
      tool = %{
        "name" => "list_things",
        "description" => "lists",
        "inputSchema" => %{},
        "annotations" => %{"readOnlyHint" => true}
      }

      assert Spec.from_mcp(tool, "srv").read_only? == true
    end

    test "from_mcp defaults read_only? to false without the annotation" do
      assert Spec.from_mcp(%{"name" => "do_thing"}, "srv").read_only? == false
    end
  end

  describe "from_module/1" do
    test "builds spec with name/description/schema from module callbacks" do
      spec = Spec.from_module(FakeModTool)

      assert spec.kind == :module
      assert spec.module == FakeModTool
      assert spec.name == "fake_mod"
      assert spec.description == "A fake module tool"
      assert spec.schema == %{type: "object", properties: %{}, required: []}
    end

    test "parallel_safe? is true when module implements it returning true" do
      spec = Spec.from_module(FakeModTool)
      assert spec.parallel_safe? == true
    end

    test "parallel_safe? is false when module does not implement optional callback" do
      spec = Spec.from_module(FakeModToolNoParallel)
      assert spec.parallel_safe? == false
    end

    test "mcp fields are nil for module spec" do
      spec = Spec.from_module(FakeModTool)
      assert is_nil(spec.mcp_server)
      assert is_nil(spec.mcp_tool_name)
    end
  end

  describe "from_mcp/2" do
    @tool_map %{
      "name" => "bash",
      "description" => "Run a bash command",
      "inputSchema" => %{"type" => "object", "properties" => %{}, "required" => []}
    }

    test "builds spec with namespaced name" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.name == "myserver_bash"
    end

    test "retains original tool name as mcp_tool_name" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.mcp_tool_name == "bash"
    end

    test "stores server name" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.mcp_server == "myserver"
    end

    test "kind is :mcp" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.kind == :mcp
    end

    test "module is nil" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert is_nil(spec.module)
    end

    test "parallel_safe? is false (MCP tools are never assumed read-only)" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.parallel_safe? == false
    end

    test "copies description" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.description == "Run a bash command"
    end

    test "uses inputSchema as schema" do
      spec = Spec.from_mcp(@tool_map, "myserver")
      assert spec.schema == %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end

  describe "execute/3" do
    test "dispatches :module kind through module.execute/2" do
      spec = Spec.from_module(FakeModTool)
      ctx = %{}
      assert {:ok, "hello"} = Spec.execute(spec, %{"echo" => "hello"}, ctx)
    end

    test "dispatches :mcp kind through ExAthena.Mcp.Tool.execute/3" do
      # Verified through the Mcp.Tool integration test; here we just confirm
      # the dispatch happens (server not running → expected error shape).
      spec =
        Spec.from_mcp(%{"name" => "bash", "description" => "d", "inputSchema" => %{}}, "ghost")

      ctx = %{}
      assert {:error, {:mcp_server_not_running, "ghost"}} = Spec.execute(spec, %{}, ctx)
    end
  end

  describe "parallel_safe?/1" do
    test "returns the cached field value" do
      assert Spec.parallel_safe?(Spec.from_module(FakeModTool)) == true
      assert Spec.parallel_safe?(Spec.from_module(FakeModToolNoParallel)) == false

      assert Spec.parallel_safe?(
               Spec.from_mcp(%{"name" => "x", "description" => "d", "inputSchema" => %{}}, "s")
             ) == false
    end
  end
end

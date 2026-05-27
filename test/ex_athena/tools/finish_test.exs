defmodule ExAthena.Tools.FinishTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tools.Finish

  describe "Tool behaviour" do
    test "name/0 returns finish" do
      assert Finish.name() == "finish"
    end

    test "description/0 is non-empty" do
      assert is_binary(Finish.description())
      assert byte_size(Finish.description()) > 0
    end

    test "schema/0 is a valid JSON schema object with optional fields" do
      schema = Finish.schema()
      assert schema.type == "object"

      assert Map.has_key?(schema.properties, :summary) or
               Map.has_key?(schema.properties, "summary")

      assert Map.has_key?(schema.properties, :deliverable) or
               Map.has_key?(schema.properties, "deliverable")

      assert schema.required == [] or schema[:required] == []
    end

    test "parallel_safe?/0 returns false" do
      refute Finish.parallel_safe?()
    end
  end

  describe "execute/2" do
    test "returns {:halt, {:submitted, deliverable}} with deliverable from args" do
      assert {:halt, {:submitted, "my plan"}} =
               Finish.execute(%{"deliverable" => "my plan"}, %{})
    end

    test "accepts summary as alias for deliverable" do
      assert {:halt, {:submitted, "task done"}} =
               Finish.execute(%{"summary" => "task done"}, %{})
    end

    test "prefers deliverable over summary when both present" do
      assert {:halt, {:submitted, "the deliverable"}} =
               Finish.execute(%{"deliverable" => "the deliverable", "summary" => "ignored"}, %{})
    end

    test "returns {:halt, {:submitted, nil}} when no args given" do
      assert {:halt, {:submitted, nil}} = Finish.execute(%{}, %{})
    end
  end
end

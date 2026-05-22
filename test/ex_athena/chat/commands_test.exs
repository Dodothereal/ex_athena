defmodule ExAthena.Chat.CommandsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Commands

  describe "parse/1" do
    test "treats plain text as a user message" do
      assert Commands.parse("hello there") == {:message, "hello there"}
    end

    test "trims surrounding whitespace from a user message" do
      assert Commands.parse("  hello  \n") == {:message, "hello"}
    end

    test "returns :noop for blank input" do
      assert Commands.parse("") == :noop
      assert Commands.parse("   ") == :noop
      assert Commands.parse("\n") == :noop
    end

    test "returns :exit for :eof" do
      assert Commands.parse(:eof) == :exit
    end

    test "returns :exit for /exit, /quit, /q" do
      assert Commands.parse("/exit") == :exit
      assert Commands.parse("/quit") == :exit
      assert Commands.parse("/q") == :exit
      assert Commands.parse("  /exit  ") == :exit
    end

    test "parses /model with no args" do
      assert Commands.parse("/model") == {:command, :model, []}
    end

    test "parses /model with an inline argument" do
      assert Commands.parse("/model qwen2.5-coder:14b") ==
               {:command, :model, ["qwen2.5-coder:14b"]}
    end

    test "parses /mode with no args" do
      assert Commands.parse("/mode") == {:command, :mode, []}
    end

    test "parses /mode with an inline argument" do
      assert Commands.parse("/mode plan_and_solve") == {:command, :mode, ["plan_and_solve"]}
    end

    test "parses /tools" do
      assert Commands.parse("/tools") == {:command, :tools, []}
    end

    test "parses /clear" do
      assert Commands.parse("/clear") == {:command, :clear, []}
    end

    test "parses /expand with no args (latest tool result)" do
      assert Commands.parse("/expand") == {:command, :expand, []}
    end

    test "parses /expand N with a numeric position" do
      assert Commands.parse("/expand 3") == {:command, :expand, ["3"]}
    end

    test "parses /help and /?" do
      assert Commands.parse("/help") == {:command, :help, []}
      assert Commands.parse("/?") == {:command, :help, []}
    end

    test "returns {:unknown, name} for unrecognized slash commands" do
      assert Commands.parse("/modle") == {:unknown, "modle"}
      assert Commands.parse("/foo bar") == {:unknown, "foo"}
    end

    test "is case-insensitive on the command verb" do
      assert Commands.parse("/MODEL") == {:command, :model, []}
      assert Commands.parse("/Exit") == :exit
    end
  end

  describe "help_text/0" do
    test "lists every slash command with a one-line description" do
      text = Commands.help_text()

      for verb <-
            ~w(/model /mode /tools /clear /expand /details /cd /pwd /tab /diff /timeline /help /exit) do
        assert text =~ verb, "expected help text to mention #{verb}"
      end
    end
  end

  describe "parse/1 /cd and /pwd" do
    test "parses /cd PATH" do
      assert Commands.parse("/cd ~/test") == {:command, :cd, ["~/test"]}
      assert Commands.parse("/cd") == {:command, :cd, []}
    end

    test "parses /pwd" do
      assert Commands.parse("/pwd") == {:command, :pwd, []}
    end
  end

  describe "parse/1 /details" do
    test "parses /details with no args" do
      assert Commands.parse("/details") == {:command, :details, []}
    end

    test "parses /details on and /details off" do
      assert Commands.parse("/details on") == {:command, :details, ["on"]}
      assert Commands.parse("/details off") == {:command, :details, ["off"]}
    end
  end

  describe "parse/1 details tab commands" do
    test "parses /tab, /diff, /timeline" do
      assert Commands.parse("/tab") == {:command, :tab, []}
      assert Commands.parse("/diff") == {:command, :diff, []}
      assert Commands.parse("/timeline") == {:command, :timeline, []}
    end
  end
end

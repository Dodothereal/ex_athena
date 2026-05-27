defmodule ExAthena.Loop.HooksModesTest do
  @moduledoc """
  PR3a — verifies the expanded hook surface and the new permission modes.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.{Message, ToolCall}
  alias ExAthena.Permissions.Denial

  defp single_text(text) do
    fn _req -> %Response{text: text, finish_reason: :stop, provider: :mock} end
  end

  defp tool_then_stop(tool_name, args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "calling",
            tool_calls: [%ToolCall{id: "c1", name: tool_name, arguments: args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "ok", finish_reason: :stop, provider: :mock}
      end
    end
  end

  describe "hooks catalog" do
    test "Hooks.events/0 enumerates every supported event" do
      events = ExAthena.Hooks.events()
      assert :SessionStart in events
      assert :SessionEnd in events
      assert :UserPromptSubmit in events
      assert :ChatParams in events
      assert :Stop in events
      assert :StopFailure in events
      assert :PreToolUse in events
      assert :PostToolUse in events
      assert :PostToolUseFailure in events
      assert :PermissionRequest in events
      assert :PermissionDenied in events
      assert :SubagentStart in events
      assert :SubagentStop in events
      assert :PreIteration in events
      assert :PreCompact in events
      assert :PreCompactStage in events
      assert :PostCompact in events
      assert :Notification in events
    end
  end

  describe "Stop / StopFailure / SessionEnd" do
    test "Stop fires on a clean termination" do
      ref = make_ref()
      parent = self()

      hooks = %{
        Stop: [
          fn p, _ ->
            send(parent, {ref, :stop, p.finish_reason})
            :ok
          end
        ],
        StopFailure: [
          fn _p, _ ->
            send(parent, {ref, :stop_failure})
            :ok
          end
        ],
        SessionEnd: [
          fn _p, _ ->
            send(parent, {ref, :session_end})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text("ok")],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, :stop, :stop}
      assert_receive {^ref, :session_end}
      refute_received {^ref, :stop_failure}
    end

    test "StopFailure fires on max-iterations termination" do
      responder = fn _req ->
        %Response{
          text: "",
          tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "x"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end

      ref = make_ref()
      parent = self()

      hooks = %{
        Stop: [
          fn _p, _ ->
            send(parent, {ref, :stop})
            :ok
          end
        ],
        StopFailure: [
          fn p, _ ->
            send(parent, {ref, :stop_failure, p.finish_reason})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("spin",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          hooks: hooks,
          memory: false,
          max_iterations: 1
        )

      assert_receive {^ref, :stop_failure, :error_max_turns}
      refute_received {^ref, :stop}
    end
  end

  describe "UserPromptSubmit transform + inject" do
    test "{:transform, prompt} rewrites the user message" do
      ref = make_ref()
      parent = self()

      hooks = %{
        UserPromptSubmit: [fn _p, _ -> {:transform, "rewritten by hook"} end]
      }

      responder = fn req ->
        send(parent, {ref, req.messages})
        %Response{text: "ok", finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("original prompt",
          provider: :mock,
          mock: [responder: responder],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, messages}
      user = Enum.find(messages, &match?(%Message{role: :user}, &1))
      assert user.content == "rewritten by hook"
    end

    test "{:inject, msg} appends a context message" do
      ref = make_ref()
      parent = self()

      injected = %Message{role: :system, content: "extra context", name: "injected"}

      hooks = %{
        UserPromptSubmit: [fn _p, _ -> {:inject, injected} end]
      }

      responder = fn req ->
        send(parent, {ref, req.messages})
        %Response{text: "ok", finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, messages}

      assert Enum.any?(messages, fn m ->
               m.role == :system and m.name == "injected"
             end)
    end
  end

  describe "ChatParams" do
    test "fires before each provider call and {:inject, msg} appends to messages" do
      ref = make_ref()
      parent = self()

      hooks = %{
        ChatParams: [
          fn _p, _ ->
            send(parent, {ref, :chat_params})

            {:inject, %Message{role: :system, content: "extra", name: "from-chatparams"}}
          end
        ]
      }

      responder = fn req ->
        send(parent, {ref, :messages, req.messages})
        %Response{text: "ok", finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, :chat_params}
      assert_receive {^ref, :messages, messages}
      assert Enum.any?(messages, &match?(%Message{name: "from-chatparams"}, &1))
    end
  end

  describe "PermissionDenied" do
    test "fires when a denylist match denies a tool call" do
      ref = make_ref()
      parent = self()

      hooks = %{
        PermissionDenied: [
          fn p, _ ->
            send(parent, {ref, :permission_denied, p.tool_name, p.reason})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: tool_then_stop("bash", %{"command" => "ls"})],
          tools: [ExAthena.Tools.Bash],
          disallowed_tools: ["bash"],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, :permission_denied, "bash",
                      %Denial{code: :user_denied, metadata: %{requested_tool: "bash"}}}
    end
  end

  describe "PostToolUseFailure" do
    test "fires when a tool returns {:error, _}" do
      ref = make_ref()
      parent = self()

      hooks = %{
        PostToolUseFailure: [
          fn p, _ ->
            send(parent, {ref, :post_tool_use_failure, p.tool_name})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: tool_then_stop("read", %{"path" => "/nonexistent"})],
          tools: [ExAthena.Tools.Read],
          hooks: hooks,
          memory: false,
          max_iterations: 3
        )

      assert_receive {^ref, :post_tool_use_failure, "read"}
    end
  end

  describe "PreIteration hook" do
    test "catalog includes :PreIteration" do
      assert :PreIteration in ExAthena.Hooks.events()
    end

    test "fires every iteration with correct payload" do
      parent = self()
      ref = make_ref()

      hooks = %{
        PreIteration: [
          fn p, _ ->
            send(parent, {ref, :pre_iter, p})
            :ok
          end
        ]
      }

      counter = :counters.new(1, [:atomics])

      responder = fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          n when n < 3 ->
            %Response{
              text: "step #{n}",
              tool_calls: [
                %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "/f#{n}"}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "done", finish_reason: :stop, provider: :mock}
        end
      end

      {:ok, _} =
        Loop.run("go",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          hooks: hooks,
          memory: false
        )

      assert_receive {^ref, :pre_iter, %{iteration: 0, unproductive_iterations: 0}}
      assert_receive {^ref, :pre_iter, %{iteration: 1}}
      assert_receive {^ref, :pre_iter, %{iteration: 2}}
    end

    test "{:inject, msg} adds a message before the model sees the next turn" do
      injected = %Message{
        role: :system,
        content: "nudge from PreIteration",
        name: "pre-iter-inject"
      }

      hooks = %{
        PreIteration: [fn _p, _ -> {:inject, injected} end]
      }

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text("ok")],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert Enum.any?(result.messages, fn m ->
               m.role == :system and m.name == "pre-iter-inject"
             end)
    end

    test "{:halt, reason} stops with finish_reason: :error_halted" do
      hooks = %{
        PreIteration: [
          fn %{iteration: iter}, _ ->
            if iter == 1, do: {:halt, :my_reason}, else: :ok
          end
        ]
      }

      responder = fn _req ->
        %Response{
          text: "thinking",
          tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "/x"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          hooks: hooks,
          memory: false
        )

      assert result.finish_reason == :error_halted
      assert result.halted_reason == :my_reason
    end

    test ":ok / :continue allows normal completion" do
      hooks = %{
        PreIteration: [fn _p, _ -> :ok end]
      }

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text("done")],
          tools: [],
          hooks: hooks,
          memory: false
        )

      assert result.finish_reason == :stop
    end

    test "unproductive_iterations increments in payload and hook can halt before :error_no_progress" do
      parent = self()
      ref = make_ref()

      hooks = %{
        PreIteration: [
          fn p, _ ->
            send(parent, {ref, :pre_iter, p})

            if p.unproductive_iterations >= 2 do
              {:halt, :stalled}
            else
              :ok
            end
          end
        ]
      }

      responder = fn _req ->
        %Response{
          text: "",
          tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "/same"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          hooks: hooks,
          memory: false,
          max_unproductive_iterations: 5
        )

      assert result.finish_reason == :error_halted
      assert result.halted_reason == :stalled

      assert_receive {^ref, :pre_iter, %{unproductive_iterations: 0}}
      assert_receive {^ref, :pre_iter, %{unproductive_iterations: 0}}
      assert_receive {^ref, :pre_iter, %{unproductive_iterations: 1}}
      assert_receive {^ref, :pre_iter, %{unproductive_iterations: 2}}
    end
  end

  describe "permission modes" do
    alias ExAthena.{Permissions, ToolContext}

    defp call(name, args \\ %{}), do: %ToolCall{id: "c1", name: name, arguments: args}
    defp ctx(phase), do: ToolContext.new(cwd: "/tmp", phase: phase)

    test ":accept_edits auto-allows file edits without consulting the callback" do
      callback_called = :counters.new(1, [:atomics])

      cb = fn _, _, _ ->
        :counters.add(callback_called, 1, 1)
        {:deny, :would_have_denied}
      end

      assert :allow =
               Permissions.check(call("edit"), ctx(:accept_edits), %{can_use_tool: cb})

      assert :allow =
               Permissions.check(call("write"), ctx(:accept_edits), %{can_use_tool: cb})

      assert :counters.get(callback_called, 1) == 0
    end

    test ":accept_edits still consults the callback for non-edit tools" do
      cb = fn "bash", _, _ -> {:deny, :user_declined} end

      assert {:deny, %Denial{code: :user_denied, metadata: %{raw: :user_declined}}} =
               Permissions.check(call("bash"), ctx(:accept_edits), %{can_use_tool: cb})
    end

    test ":trusted skips the callback for every tool" do
      cb = fn _, _, _ -> {:deny, :would_have_denied} end

      assert :allow = Permissions.check(call("bash"), ctx(:trusted), %{can_use_tool: cb})

      assert :allow =
               Permissions.check(call("custom_tool"), ctx(:trusted), %{can_use_tool: cb})
    end

    test ":trusted respects the denylist by default" do
      assert {:deny, %Denial{code: :user_denied, metadata: %{requested_tool: "bash"}}} =
               Permissions.check(call("bash"), ctx(:trusted), disallowed_tools: ["bash"])
    end

    test ":trusted with respect_denylist: false bypasses the denylist" do
      assert :allow =
               Permissions.check(call("bash"), ctx(:trusted),
                 disallowed_tools: ["bash"],
                 respect_denylist: false
               )
    end

    test ":bypass_permissions still respects the denylist (deny-first invariant)" do
      assert {:deny, %Denial{code: :user_denied, metadata: %{requested_tool: "bash"}}} =
               Permissions.check(call("bash"), ctx(:bypass_permissions),
                 disallowed_tools: ["bash"]
               )
    end
  end
end

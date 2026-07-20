defmodule ExAthena.PermissionsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.Permissions.Denial
  alias ExAthena.{Permissions, ToolContext}

  doctest ExAthena.Permissions

  defp ctx(phase \\ :default) do
    ToolContext.new(cwd: "/tmp", phase: phase)
  end

  defp call(name, args \\ %{}) do
    %ToolCall{id: "c1", name: name, arguments: args}
  end

  test "disallowed_tools wins over everything" do
    assert {:deny, %Denial{code: :user_denied, metadata: %{requested_tool: "bash"}}} =
             Permissions.check(call("bash"), ctx(:bypass_permissions), disallowed_tools: ["bash"])
  end

  test "allowed_tools when set denies anything not in it" do
    assert {:deny,
            %Denial{
              code: :user_denied,
              metadata: %{requested_tool: "bash", allowed_tools: ["read"]}
            }} =
             Permissions.check(call("bash"), ctx(), allowed_tools: ["read"])

    assert :allow = Permissions.check(call("read"), ctx(), allowed_tools: ["read"])
  end

  test "plan phase blocks mutation tools" do
    assert {:deny,
            %Denial{code: :phase_gated, metadata: %{phase: :plan, requested_tool: "write"}}} =
             Permissions.check(call("write"), ctx(:plan), %{})

    assert {:deny, %Denial{code: :phase_gated, metadata: %{phase: :plan, requested_tool: "edit"}}} =
             Permissions.check(call("edit"), ctx(:plan), %{})

    assert :allow = Permissions.check(call("read"), ctx(:plan), %{})
    assert :allow = Permissions.check(call("glob"), ctx(:plan), %{})
  end

  test "plan phase allows todo_write (session bookkeeping, not a workspace mutation)" do
    assert :allow = Permissions.check(call("todo_write", %{"todos" => []}), ctx(:plan), %{})
  end

  test "plan phase allows web_search (read-only online research)" do
    assert :allow = Permissions.check(call("web_search", %{"query" => "q"}), ctx(:plan), %{})
    assert "web_search" in Permissions.readonly_tools()
  end

  describe "plan phase — bash gating" do
    test "allows read-only bash commands (cat, ls, grep, gh, git log/diff/status)" do
      for cmd <- [
            "cat lib/foo.ex",
            "ls -la",
            "grep -r Foo lib/",
            "find . -name *.ex",
            "gh issue view 58",
            "git log --oneline -10",
            "git diff",
            "git status",
            "head -50 README.md",
            "tail -30 mix.exs",
            "wc -l lib/foo.ex",
            "mix help"
          ] do
        assert :allow = Permissions.check(call("bash", %{"command" => cmd}), ctx(:plan), %{}),
               "expected read-only `#{cmd}` to be allowed in plan phase"
      end
    end

    test "denies write/destructive bash commands" do
      for cmd <- [
            "rm -rf foo",
            "mkdir new_dir",
            "touch new.ex",
            "mv a b",
            "cp a b",
            "echo hi > out.txt",
            "echo hi >> out.txt",
            "git add lib/foo.ex",
            "git commit -m wip",
            "git push",
            "mix ecto.migrate",
            "mix ash.codegen something",
            "npm install foo",
            "sed -i s/foo/bar/ file.ex"
          ] do
        assert {:deny,
                %Denial{
                  code: :phase_gated,
                  metadata: %{phase: :plan, requested_tool: "bash"}
                }} = Permissions.check(call("bash", %{"command" => cmd}), ctx(:plan), %{}),
               "expected write/destructive `#{cmd}` to be denied in plan phase"
      end
    end

    test "denies bash with missing command (defensive — treat as not read-only)" do
      assert {:deny, %Denial{code: :phase_gated}} =
               Permissions.check(call("bash", %{}), ctx(:plan), %{})
    end

    test "denies interpreter one-liners and unknown commands (allowlist, not blocklist)" do
      for cmd <- [
            ~s{python -c "open('x','w').write('pwned')"},
            ~s{python3 -c "import os; os.remove('x')"},
            ~s{perl -e 'unlink "x"'},
            ~s{ruby -e 'File.delete("x")'},
            ~s{node -e "require('fs').writeFileSync('x','y')"},
            "ex file.txt",
            "ed file.txt",
            ~s{sh -c "rm -rf x"},
            ~s{bash -c "echo pwned"},
            "some_unknown_binary --flag"
          ] do
        assert {:deny, %Denial{code: :phase_gated, metadata: %{requested_tool: "bash"}}} =
                 Permissions.check(call("bash", %{"command" => cmd}), ctx(:plan), %{}),
               "expected `#{cmd}` to be denied in plan phase (unknown/interpreter commands are not read-only)"
      end
    end

    test "denies command substitution and stray redirects" do
      for cmd <- [
            "cat $(rm -rf x)",
            "cat `rm -rf x`",
            "ls > out.txt",
            "echo hi >out.txt",
            "find . -delete",
            "find . -name '*.ex' -exec rm {} \\;",
            "sort -o out.txt in.txt"
          ] do
        assert {:deny, %Denial{code: :phase_gated}} =
                 Permissions.check(call("bash", %{"command" => cmd}), ctx(:plan), %{}),
               "expected `#{cmd}` to be denied in plan phase"
      end
    end

    test "allows read-only compounds, pipes, quoted metacharacters, and null redirects" do
      for cmd <- [
            "git log --oneline | head -5",
            "ls -la 2>/dev/null",
            "ls 2>&1",
            ~s(grep -E "foo|bar" lib/),
            "cat a.txt; ls",
            "grep -r Foo lib/ && echo found"
          ] do
        assert :allow = Permissions.check(call("bash", %{"command" => cmd}), ctx(:plan), %{}),
               "expected read-only `#{cmd}` to be allowed in plan phase"
      end
    end

    test "bash is unrestricted in :default phase" do
      assert :allow =
               Permissions.check(call("bash", %{"command" => "rm -rf foo"}), ctx(), %{})
    end
  end

  describe "plan phase — deny-by-default for tools not known read-only" do
    test "denies MCP/custom tools that are not opted in" do
      assert {:deny,
              %Denial{
                code: :phase_gated,
                metadata: %{phase: :plan, requested_tool: "myserver_create_ticket"}
              }} = Permissions.check(call("myserver_create_ticket"), ctx(:plan), %{})
    end

    test "denies apply_patch (mutating tool outside the static lists)" do
      assert {:deny, %Denial{code: :phase_gated}} =
               Permissions.check(call("apply_patch"), ctx(:plan), %{})
    end

    test "allows tools opted in via the readonly_tools opt" do
      opts = %{readonly_tools: ["myserver_list_tickets"]}

      assert :allow = Permissions.check(call("myserver_list_tickets"), ctx(:plan), opts)
      assert {:deny, _} = Permissions.check(call("myserver_create_ticket"), ctx(:plan), opts)
    end

    test "allows session-control tools (ask_user, finish) — they never touch the workspace" do
      assert :allow = Permissions.check(call("ask_user"), ctx(:plan), %{})
      assert :allow = Permissions.check(call("finish"), ctx(:plan), %{})
    end

    test "deny-by-default only applies to :plan — :default still allows unknown tools" do
      assert :allow = Permissions.check(call("myserver_create_ticket"), ctx(), %{})
    end
  end

  describe "plan_mode exit gating" do
    test "run pinned to :plan by the host, no can_use_tool → exit denied" do
      assert {:deny,
              %Denial{code: :phase_gated, metadata: %{phase: :plan, requested_tool: "plan_mode"}}} =
               Permissions.check(
                 call("plan_mode", %{"action" => "exit"}),
                 ctx(:plan),
                 %{phase: :plan}
               )
    end

    test "run pinned to :plan, can_use_tool consulted — approval allows the exit" do
      parent = self()

      approve = fn name, args, _ctx ->
        send(parent, {:asked, name, args})
        :allow
      end

      assert :allow =
               Permissions.check(
                 call("plan_mode", %{"action" => "exit"}),
                 ctx(:plan),
                 %{phase: :plan, can_use_tool: approve}
               )

      assert_received {:asked, "plan_mode", %{"action" => "exit"}}
    end

    test "run pinned to :plan, can_use_tool can deny the exit" do
      deny = fn "plan_mode", %{"action" => "exit"}, _ctx -> {:deny, :user_declined} end

      assert {:deny, %Denial{code: :user_denied}} =
               Permissions.check(
                 call("plan_mode", %{"action" => "exit"}),
                 ctx(:plan),
                 %{phase: :plan, can_use_tool: deny}
               )
    end

    test "model self-entered plan from :default → exit needs no approval" do
      assert :allow =
               Permissions.check(
                 call("plan_mode", %{"action" => "exit"}),
                 ctx(:plan),
                 %{phase: :default}
               )
    end

    test "enter is always allowed, even in a host-pinned :plan run" do
      assert :allow =
               Permissions.check(
                 call("plan_mode", %{"action" => "enter"}),
                 ctx(:plan),
                 %{phase: :plan}
               )
    end
  end

  test "bypass_permissions allows everything" do
    assert :allow = Permissions.check(call("bash"), ctx(:bypass_permissions), %{})
    assert :allow = Permissions.check(call("write"), ctx(:bypass_permissions), %{})
  end

  test "can_use_tool callback can deny with reason" do
    deny = fn _name, _args, _ctx -> {:deny, :user_declined} end

    assert {:deny, %Denial{code: :user_denied, metadata: %{raw: :user_declined}}} =
             Permissions.check(call("bash"), ctx(), %{can_use_tool: deny})
  end

  test "can_use_tool callback can allow" do
    allow = fn _name, _args, _ctx -> :allow end

    assert :allow = Permissions.check(call("bash"), ctx(), %{can_use_tool: allow})
  end

  test "plan phase denial carries allowed_tools in metadata" do
    {:deny, denial} = Permissions.check(call("write"), ctx(:plan), %{})
    assert denial.code == :phase_gated
    assert denial.metadata.requested_tool == "write"
    assert denial.metadata.phase == :plan
    assert is_list(denial.metadata.allowed_tools)
  end

  test "not_in_allowlist denial carries allowed list in metadata" do
    {:deny, denial} = Permissions.check(call("bash"), ctx(), allowed_tools: ["read"])
    assert denial.code == :user_denied
    assert denial.metadata.allowed_tools == ["read"]
  end

  test "Denial implements String.Chars" do
    {:deny, denial} = Permissions.check(call("write"), ctx(:plan), %{})
    assert is_binary(to_string(denial))
  end

  describe "plan_mode_tools/0" do
    test "is readonly_tools/0 plus bash" do
      assert Permissions.plan_mode_tools() == Permissions.readonly_tools() ++ ["bash"]
    end

    test "includes bash" do
      assert "bash" in Permissions.plan_mode_tools()
    end

    test "includes the existing readonly set" do
      for tool <- Permissions.readonly_tools() do
        assert tool in Permissions.plan_mode_tools()
      end
    end
  end
end

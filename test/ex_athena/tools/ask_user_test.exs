defmodule ExAthena.Tools.AskUserTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tools.AskUser

  defp ctx(assigns) do
    ExAthena.ToolContext.new(
      cwd: System.tmp_dir!(),
      session_id: "s",
      assigns: assigns
    )
    |> Map.put(:tool_call_id, "tc-1")
  end

  test "blocks until the host answers and returns an unmistakable answer line" do
    test_pid = self()

    task =
      Task.async(fn ->
        AskUser.execute(
          %{"question" => "Which topic?", "options" => ["A", "B"]},
          ctx(%{ask_user: test_pid})
        )
      end)

    assert_receive {:athena_ask_user,
                    %{tool_call_id: "tc-1", question: "Which topic?", options: ["A", "B"]}}

    send(task.pid, {:athena_user_answer, "tc-1", "B"})

    # The result must be impossible for a small model to miss: it states that
    # the user ANSWERED and instructs the model to act, not ask again.
    assert {:ok, content} = Task.await(task)
    assert content =~ ~s(The user answered: "B")
    assert content =~ "do not ask again"
  end

  test "errors clearly when no interactive host is wired" do
    assert {:error, msg} = AskUser.execute(%{"question" => "Hm?"}, ctx(%{}))
    assert msg =~ "best judgement"
  end
end

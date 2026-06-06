defmodule ExAthena.Tools.AskUser do
  @moduledoc """
  Ask the human a clarifying question mid-run and block until they answer.

  This tool only works when the host wires an interactive channel into the
  tool context: `assigns: %{ask_user: pid}`, where `pid` receives an
  `{:athena_ask_user, question}` message and replies with
  `{:athena_user_answer, tool_call_id, answer}`. The LiveView chat UI does
  this; headless runs (CLI, cron) do not, so the tool returns an error there
  telling the model to proceed on its own judgement instead of hanging.

  Because the tool returns `parallel_safe?: false`, it executes serially in
  the run-loop process. The blocking `receive` therefore pauses the *entire*
  agent loop until the user answers — exactly the "wait for input" semantics
  we want — without a per-tool timeout killing it (only the concurrent
  dispatch path applies `tool_timeout_ms`).
  """

  @behaviour ExAthena.Tool

  @impl true
  def name, do: "ask_user"

  @impl true
  def description,
    do:
      "Ask the user a clarifying question and wait for their reply. Use this when you " <>
        "are blocked on a decision only the user can make (ambiguous requirements, a " <>
        "choice between approaches, missing information). Prefer this over guessing when " <>
        "guessing wrong would waste significant work. Returns the user's answer as text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        question: %{
          type: "string",
          description: "The question to ask the user. Be specific and self-contained."
        },
        options: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Optional list of suggested answers, shown to the user as quick-pick buttons. " <>
              "The user may still type a free-form reply."
        }
      },
      required: ["question"]
    }
  end

  @impl true
  def parallel_safe?, do: false

  @impl true
  def execute(args, ctx) do
    question = Map.get(args, "question")
    options = args |> Map.get("options", []) |> List.wrap() |> Enum.filter(&is_binary/1)
    host = Map.get(ctx.assigns, :ask_user)

    cond do
      not is_binary(question) or question == "" ->
        {:error, ~s(ask_user requires a non-empty "question")}

      not is_pid(host) ->
        {:error,
         "interactive questions are not available in this run; proceed using your " <>
           "best judgement instead of asking"}

      true ->
        wait_for_answer(host, ctx.tool_call_id, question, options)
    end
  end

  defp wait_for_answer(host, tool_call_id, question, options) do
    ref = Process.monitor(host)

    send(
      host,
      {:athena_ask_user, %{tool_call_id: tool_call_id, question: question, options: options}}
    )

    receive do
      {:athena_user_answer, ^tool_call_id, answer} ->
        Process.demonitor(ref, [:flush])
        {:ok, to_string(answer)}

      {:DOWN, ^ref, :process, ^host, _reason} ->
        {:error, "the user session ended before answering the question"}
    end
  end
end

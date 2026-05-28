defmodule ExAthena.Chat.Session do
  @moduledoc """
  In-memory state for one interactive `mix athena.chat` session.

  Plain struct + transformation functions — deliberately not a GenServer.
  The REPL is single-process and synchronous; each turn produces a new
  `%Session{}` from the previous one.
  """

  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}
  alias ExAthena.Result

  @default_model "llama3.1"

  defstruct provider: :ollama,
            model: @default_model,
            mode: :react,
            tools: :all,
            permission_mode: :default,
            messages: [],
            iteration: 0,
            usage: %{input_tokens: 0, output_tokens: 0},
            cost_usd: 0.0,
            cwd: nil

  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t(),
          mode: atom(),
          tools: :all | [module()],
          permission_mode: atom(),
          messages: [Message.t()],
          iteration: non_neg_integer(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          cost_usd: float(),
          cwd: String.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    provider =
      Keyword.get(opts, :provider) ||
        Application.get_env(:ex_athena, :default_provider, :ollama)

    provider_config = Application.get_env(:ex_athena, provider, [])
    configured_model = Keyword.get(provider_config, :model, @default_model)

    %__MODULE__{
      provider: provider,
      model: Keyword.get(opts, :model, configured_model),
      mode: Keyword.get(opts, :mode, :react),
      tools: Keyword.get(opts, :tools, :all),
      permission_mode: Keyword.get(opts, :permission_mode, :default),
      cwd: Keyword.get(opts, :cwd)
    }
  end

  @spec set_cwd(t(), String.t() | nil) :: t()
  def set_cwd(%__MODULE__{} = session, cwd) when is_binary(cwd) or is_nil(cwd) do
    %{session | cwd: cwd}
  end

  @spec append_user(t(), String.t()) :: t()
  def append_user(%__MODULE__{messages: msgs} = session, text) when is_binary(text) do
    %{session | messages: msgs ++ [Messages.user(text)]}
  end

  @spec clear_messages(t()) :: t()
  def clear_messages(%__MODULE__{} = session) do
    %{
      session
      | messages: [],
        iteration: 0,
        usage: %{input_tokens: 0, output_tokens: 0},
        cost_usd: 0.0
    }
  end

  @spec set_model(t(), String.t()) :: t()
  def set_model(%__MODULE__{} = session, model) when is_binary(model) do
    %{session | model: model}
  end

  @spec set_mode(t(), atom()) :: t()
  def set_mode(%__MODULE__{} = session, mode) when is_atom(mode) do
    %{session | mode: mode}
  end

  @spec set_provider(t(), atom()) :: t()
  def set_provider(%__MODULE__{} = session, provider) when is_atom(provider) do
    %{session | provider: provider}
  end

  @doc """
  Extract every `ToolResult` from the session's message history, ordered
  most-recent first.

  Used by `/expand` in the REPL so the user can reference recent tool
  outputs by position (`/expand 1` for the latest, `/expand 2` for the
  one before, etc.).
  """
  @spec tool_results(t()) :: [ToolResult.t()]
  def tool_results(%__MODULE__{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(&(&1.tool_results || []))
    |> Enum.reverse()
  end

  @spec apply_result(t(), Result.t()) :: t()
  def apply_result(%__MODULE__{} = session, %Result{} = result) do
    new_messages =
      case result.messages do
        [] -> session.messages
        msgs when is_list(msgs) -> msgs
      end

    delta_usage = result.usage || %{}

    merged_usage = %{
      input_tokens: session.usage.input_tokens + Map.get(delta_usage, :input_tokens, 0),
      output_tokens: session.usage.output_tokens + Map.get(delta_usage, :output_tokens, 0)
    }

    %{
      session
      | messages: new_messages,
        usage: merged_usage,
        cost_usd: session.cost_usd + (result.cost_usd || 0.0),
        iteration: result.iterations || session.iteration
    }
  end
end

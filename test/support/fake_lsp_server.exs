defmodule FakeLspServer do
  @moduledoc """
  Minimal LSP server script for testing ExAthena.Lsp.Client.

  Run as: elixir test/support/fake_lsp_server.exs

  No external dependencies required — uses only OTP stdlib.

  State flags:
    * `:suppress_next_diag` — if true, the next textDocument/didOpen will NOT
      emit publishDiagnostics (flag resets after use).
    * `:fail_next_request` — if true, the next request with an `id` will reply
      with a MethodNotFound error (flag resets after use).
  """

  # --- JSON encode (subset sufficient for LSP responses) ---

  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(:null), do: "null"
  def encode(n) when is_integer(n), do: Integer.to_string(n)
  def encode(f) when is_float(f), do: Float.to_string(f)

  def encode(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end

  def encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  def encode(map) when is_map(map) do
    pairs =
      Enum.map_join(map, ",", fn {k, v} ->
        "#{encode(to_string(k))}:#{encode(v)}"
      end)

    "{#{pairs}}"
  end

  # --- JSON decode using OTP 27 :json ---
  # :json.decode maps JSON null → :null (not nil)

  def decode(bin), do: :json.decode(bin)

  # --- server loop ---
  # Uses Port.open({:fd, 0, 1}, ...) to communicate via raw file descriptors,
  # bypassing Erlang's IO system which is unreliable in port-subprocess context.

  def run do
    port = Port.open({:fd, 0, 1}, [:binary, :eof])
    fail_init = System.get_env("FAKE_LSP_FAIL_INITIALIZE") == "1"

    loop(port, "", %{
      suppress_next_diag: false,
      fail_next_request: false,
      fail_initialize: fail_init
    })
  end

  defp loop(port, buffer, state) do
    receive do
      {^port, {:data, data}} ->
        process_buffer(port, buffer <> data, state)

      {^port, :eof} ->
        :ok

      _other ->
        loop(port, buffer, state)
    end
  end

  defp process_buffer(port, buffer, state) do
    case read_frame(buffer) do
      {:ok, body, rest} ->
        msg = decode(body)
        new_state = handle(msg, port, state)
        process_buffer(port, rest, new_state)

      {:need_more, buf} ->
        loop(port, buf, state)
    end
  end

  defp read_frame(buf) do
    case parse_header(buf) do
      {:ok, len, body_buf} when byte_size(body_buf) >= len ->
        <<body::binary-size(len), remaining::binary>> = body_buf
        {:ok, body, remaining}

      _ ->
        {:need_more, buf}
    end
  end

  defp parse_header(buf) do
    with {cl_start, _} <- :binary.match(buf, "Content-Length:"),
         rest <- binary_part(buf, cl_start, byte_size(buf) - cl_start),
         {eol_pos, eol_len} <- find_eol(rest),
         # "Content-Length:" is 15 chars; skip it and trim for the digits
         digits_part <- rest |> binary_part(15, eol_pos - 15) |> String.trim(),
         {len, ""} <- Integer.parse(digits_part),
         after_first <- binary_part(rest, eol_pos + eol_len, byte_size(rest) - eol_pos - eol_len),
         {:ok, body_offset} <- skip_to_body(after_first) do
      body_buf = binary_part(after_first, body_offset, byte_size(after_first) - body_offset)
      {:ok, len, body_buf}
    else
      _ -> :error
    end
  end

  defp find_eol(buf) do
    case :binary.match(buf, "\r\n") do
      {pos, 2} ->
        {pos, 2}

      :nomatch ->
        case :binary.match(buf, "\n") do
          {pos, 1} -> {pos, 1}
          :nomatch -> nil
        end
    end
  end

  defp skip_to_body(buf) do
    cond do
      String.starts_with?(buf, "\r\n") ->
        {:ok, 2}

      String.starts_with?(buf, "\n") ->
        {:ok, 1}

      true ->
        case :binary.match(buf, "\r\n\r\n") do
          {pos, 4} ->
            {:ok, pos + 4}

          :nomatch ->
            case :binary.match(buf, "\n\n") do
              {pos, 2} -> {:ok, pos + 2}
              :nomatch -> :error
            end
        end
    end
  end

  # --- message handlers (each returns new state) ---

  defp handle(%{"method" => "initialize", "id" => id}, port, state) do
    if state.fail_initialize do
      error_reply(port, id, -32602, "InvalidParams")
    else
      reply(port, id, %{"capabilities" => %{}})
    end

    state
  end

  defp handle(%{"method" => "shutdown", "id" => id}, port, state) do
    reply(port, id, nil)
    state
  end

  defp handle(%{"method" => "exit"}, _port, _state) do
    System.halt(0)
  end

  defp handle(%{"method" => "textDocument/echo", "id" => id, "params" => params}, port, state) do
    reply(port, id, params)
    state
  end

  # Original trigger notification — fires diagnostics for the fixed test URI.
  defp handle(%{"method" => "notif/trigger"}, port, state) do
    notify(port, "textDocument/publishDiagnostics", %{
      "uri" => "file:///test/foo.ex",
      "diagnostics" => [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 3}
          },
          "severity" => 1,
          "message" => "undefined function foo/0"
        }
      ]
    })

    state
  end

  # Suppress the next textDocument/didOpen publishDiagnostics side effect.
  defp handle(%{"method" => "notif/suppress_next_diag"}, _port, state) do
    %{state | suppress_next_diag: true}
  end

  # Synchronous request form: arms the fail_next flag and replies. Tests use
  # this to avoid racing a notification against the next request.
  defp handle(%{"method" => "notif/fail_next", "id" => id}, port, state) do
    reply(port, id, %{"armed" => true})
    %{state | fail_next_request: true}
  end

  # Make the next request (with an id) fail with a MethodNotFound error.
  defp handle(%{"method" => "notif/fail_next"}, _port, state) do
    %{state | fail_next_request: true}
  end

  # textDocument/didOpen — optionally publish diagnostics for the opened URI.
  defp handle(%{"method" => "textDocument/didOpen", "params" => params}, port, state) do
    uri = get_in(params, ["textDocument", "uri"]) || ""

    unless state.suppress_next_diag do
      notify(port, "textDocument/publishDiagnostics", %{
        "uri" => uri,
        "diagnostics" => [
          %{
            "range" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 5}
            },
            "severity" => 1,
            "message" => "undefined function foo/0"
          }
        ]
      })
    end

    %{state | suppress_next_diag: false}
  end

  # textDocument/definition — returns a deterministic single-location list.
  defp handle(
         %{"method" => "textDocument/definition", "id" => id, "params" => params},
         port,
         state
       ) do
    if state.fail_next_request do
      error_reply(port, id, -32601, "MethodNotFound")
      %{state | fail_next_request: false}
    else
      uri = get_in(params, ["textDocument", "uri"]) || ""

      reply(port, id, [
        %{
          "uri" => uri,
          "range" => %{
            "start" => %{"line" => 3, "character" => 0},
            "end" => %{"line" => 3, "character" => 10}
          }
        }
      ])

      state
    end
  end

  # textDocument/references — returns three deterministic locations.
  defp handle(
         %{"method" => "textDocument/references", "id" => id, "params" => params},
         port,
         state
       ) do
    if state.fail_next_request do
      error_reply(port, id, -32601, "MethodNotFound")
      %{state | fail_next_request: false}
    else
      uri = get_in(params, ["textDocument", "uri"]) || ""

      locations =
        Enum.map(0..2, fn i ->
          %{
            "uri" => uri,
            "range" => %{
              "start" => %{"line" => i, "character" => 0},
              "end" => %{"line" => i, "character" => 5}
            }
          }
        end)

      reply(port, id, locations)
      state
    end
  end

  # textDocument/hover — returns markdown contents.
  defp handle(%{"method" => "textDocument/hover", "id" => id, "params" => _params}, port, state) do
    if state.fail_next_request do
      error_reply(port, id, -32601, "MethodNotFound")
      %{state | fail_next_request: false}
    else
      reply(port, id, %{
        "contents" => %{"kind" => "markdown", "value" => "**doc** — doc text"}
      })

      state
    end
  end

  # workspace/symbol — returns two deterministic SymbolInformation entries,
  # echoing the query into the first symbol's name.
  defp handle(%{"method" => "workspace/symbol", "id" => id, "params" => params}, port, state) do
    if state.fail_next_request do
      error_reply(port, id, -32601, "MethodNotFound")
      %{state | fail_next_request: false}
    else
      query = Map.get(params, "query", "")

      reply(port, id, [
        %{
          "name" => query <> "_fun",
          "kind" => 12,
          "location" => %{
            "uri" => "file:///proj/lib/mod.ex",
            "range" => %{
              "start" => %{"line" => 5, "character" => 2},
              "end" => %{"line" => 5, "character" => 10}
            }
          }
        },
        %{
          "name" => "MyMod",
          "kind" => 2,
          "location" => %{
            "uri" => "file:///proj/lib/my_mod.ex",
            "range" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 5}
            }
          }
        }
      ])

      state
    end
  end

  # textDocument/documentSymbol — returns a hierarchical DocumentSymbol tree:
  # a module with one nested function.
  defp handle(
         %{"method" => "textDocument/documentSymbol", "id" => id, "params" => _params},
         port,
         state
       ) do
    if state.fail_next_request do
      error_reply(port, id, -32601, "MethodNotFound")
      %{state | fail_next_request: false}
    else
      reply(port, id, [
        %{
          "name" => "Test",
          "kind" => 2,
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 10, "character" => 3}
          },
          "selectionRange" => %{
            "start" => %{"line" => 0, "character" => 10},
            "end" => %{"line" => 0, "character" => 14}
          },
          "children" => [
            %{
              "name" => "hello/1",
              "kind" => 12,
              "range" => %{
                "start" => %{"line" => 2, "character" => 2},
                "end" => %{"line" => 4, "character" => 5}
              },
              "selectionRange" => %{
                "start" => %{"line" => 2, "character" => 6},
                "end" => %{"line" => 2, "character" => 11}
              },
              "children" => []
            }
          ]
        }
      ])

      state
    end
  end

  # Catch-all for unknown requests with id — optionally fail, otherwise MethodNotFound.
  defp handle(%{"method" => _method, "id" => id}, port, state) do
    error_reply(port, id, -32601, "MethodNotFound")
    %{state | fail_next_request: false}
  end

  # Catch-all for notifications (no id) — ignore.
  defp handle(_notification, _port, state), do: state

  # --- wire helpers ---

  defp reply(port, id, result) do
    send_msg(port, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error_reply(port, id, code, message) do
    send_msg(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp notify(port, method, params) do
    send_msg(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_msg(port, msg) do
    json = encode(msg)
    frame = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
    Port.command(port, frame)
  end
end

FakeLspServer.run()

# exo Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exo (local distributed LLM inference, `http://localhost:52415`) as a first-class provider: web dropdown entry, downloaded-model listing, context-window discovery, TUI defaults, and automatic instance activation.

**Architecture:** `:exo` already routes to `ExAthena.Providers.ReqLLM` as OpenAI-compatible (see `lib/ex_athena/config.ex:96,115,125`; placeholder API key at `lib/ex_athena/providers/req_llm.ex:381`). We add a new `ExAthena.Chat.Exo` module (mirrors `ExAthena.Chat.LlamaCpp`) for model listing + instance activation, hook activation into `Providers.ReqLLM.query/stream` pre-flight, and wire UI/TUI/ContextWindow touches. Spec: `docs/superpowers/specs/2026-06-05-exo-provider-design.md`.

**Tech Stack:** Elixir, Req (HTTP), Bypass (test HTTP server), Phoenix LiveView (UI), req_llm (LLM adapter).

**Verified exo API facts** (source copies in `tmp/exo_src/`):
- `GET /v1/models?status=downloaded` → `{"object": "list", "data": [{"id": "mlx-community/...", "context_length": 131072, ...}]}`
- `GET /state/instances` → `{"<uuid>": {"MlxRingInstance" | "MlxJacclInstance": {"shardAssignments": {"modelId": "...", ...}, ...}}}` (camelCase)
- `POST /place_instance` body `{"model_id": "..."}` → 200 `{"message": "Command received.", ...}` — **not idempotent**, must check-before-create
- Chat without an active instance → 404 `{"error": {"message": "No instance found for model <id>", ...}}`
- No authentication. Instance registration is sub-second; weight loading happens after (affects first-token latency only).

**Run tests with:** `mix test <path> --seed 0` from repo root.

---

### Task 1: `ExAthena.Chat.Exo.list_models/1`

**Files:**
- Create: `test/ex_athena/chat/exo_test.exs`
- Create: `lib/ex_athena/chat/exo.ex`

- [ ] **Step 1: Write the failing tests**

Create `test/ex_athena/chat/exo_test.exs` (mirrors `test/ex_athena/chat/ollama_test.exs`):

```elixir
defmodule ExAthena.Chat.ExoTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Exo

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "list_models/1" do
    test "returns downloaded model ids sorted alphabetically on a 200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["status"] == "downloaded"

        body =
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{"id" => "mlx-community/Qwen3-4B-4bit", "context_length" => 32_768},
              %{"id" => "mlx-community/Llama-3.2-1B-Instruct-4bit", "context_length" => 131_072}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok,
              ["mlx-community/Llama-3.2-1B-Instruct-4bit", "mlx-community/Qwen3-4B-4bit"]} =
               Exo.list_models(base_url: base_url)
    end

    test "strips a trailing /v1 from the base_url before hitting /v1/models",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"data" => []}))
      end)

      assert {:ok, []} = Exo.list_models(base_url: base_url <> "/v1")
    end

    test "returns {:error, :exo_unreachable} when the connection is refused" do
      # 1 is reserved and will reject every connect attempt fast.
      assert {:error, :exo_unreachable} = Exo.list_models(base_url: "http://127.0.0.1:1")
    end

    test "returns {:error, {:http, status}} on a non-200 response",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, {:http, 500}} = Exo.list_models(base_url: base_url)
    end

    test "returns {:error, :unexpected_response} when the body lacks a data array",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"unexpected" => "shape"}))
      end)

      assert {:error, :unexpected_response} = Exo.list_models(base_url: base_url)
    end

    test "falls back to the configured base_url when none is passed" do
      original = Application.get_env(:ex_athena, :exo)
      bypass = Bypass.open()

      on_exit(fn ->
        if original do
          Application.put_env(:ex_athena, :exo, original)
        else
          Application.delete_env(:ex_athena, :exo)
        end
      end)

      Application.put_env(:ex_athena, :exo, base_url: "http://localhost:#{bypass.port}/v1")

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"data" => [%{"id" => "x"}]}))
      end)

      assert {:ok, ["x"]} = Exo.list_models([])
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ex_athena/chat/exo_test.exs --seed 0`
Expected: FAIL — `module ExAthena.Chat.Exo is not available`

- [ ] **Step 3: Write the implementation**

Create `lib/ex_athena/chat/exo.ex`:

```elixir
defmodule ExAthena.Chat.Exo do
  @moduledoc """
  Talks to a local exo cluster's HTTP API (https://github.com/exo-explore/exo)
  for chat-time helpers.

  `list_models/1` hits `GET /v1/models?status=downloaded` and returns the model
  ids downloaded somewhere in the cluster, sorted alphabetically. exo model ids
  are full HuggingFace ids (e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`).
  """

  @default_base_url "http://localhost:52415"
  @timeout_ms 2_000

  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :exo_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_v1_suffix()
    url = base <> "/v1/models?status=downloaded"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_models(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, %Req.TransportError{}} -> {:error, :exo_unreachable}
      {:error, %Mint.TransportError{}} -> {:error, :exo_unreachable}
      {:error, _} -> {:error, :exo_unreachable}
    end
  end

  defp decode_models(%{"data" => list}) when is_list(list) do
    names =
      list
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    {:ok, names}
  end

  defp decode_models(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_models(decoded)
      {:error, _} -> {:error, :unexpected_response}
    end
  end

  defp decode_models(_), do: {:error, :unexpected_response}

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:exo, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp strip_v1_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ex_athena/chat/exo_test.exs --seed 0`
Expected: 6 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
mix format lib/ex_athena/chat/exo.ex test/ex_athena/chat/exo_test.exs
git add lib/ex_athena/chat/exo.ex test/ex_athena/chat/exo_test.exs
git commit -m "feat: add ExAthena.Chat.Exo with downloaded-model listing"
```

---

### Task 2: `ExAthena.Chat.Exo.ensure_instance/2`

**Files:**
- Modify: `test/ex_athena/chat/exo_test.exs` (append describe block)
- Modify: `lib/ex_athena/chat/exo.ex`

exo chat 404s unless the model has an active instance. `POST /place_instance` is
NOT idempotent (creates duplicate instances), so we must check
`GET /state/instances` first. "Registered in state" is the exact predicate chat
uses, so polling state (instead of parsing the `/instance/await` SSE stream) is
equivalent and far simpler.

- [ ] **Step 1: Write the failing tests**

Append inside `ExAthena.Chat.ExoTest`. NOTE: ExUnit forbids defining functions
inside `describe` blocks — `@model` and `instances_body/2` go at the module
level (right after the `setup` block), the tests inside a new describe.

```elixir
  # Module level, after the setup block:
  @model "mlx-community/Llama-3.2-1B-Instruct-4bit"

  defp instances_body(model, tag \\ "MlxRingInstance") do
    %{
      "11111111-aaaa-bbbb-cccc-000000000001" => %{
        tag => %{
          "instanceId" => "11111111-aaaa-bbbb-cccc-000000000001",
          "shardAssignments" => %{"modelId" => model, "runnerToShard" => %{}},
          "hostsByNode" => %{}
        }
      }
    }
  end

  # After the list_models/1 describe block:
  describe "ensure_instance/2" do
    test "returns :ok without placing when an instance is already active",
         %{bypass: bypass, base_url: base_url} do
      # Only GET /state/instances is expected; any POST /place_instance would
      # make Bypass fail the test as an unexpected request.
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(instances_body(@model)))
      end)

      assert :ok = Exo.ensure_instance(@model, base_url: base_url)
    end

    test "recognizes MlxJacclInstance-tagged instances",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(instances_body(@model, "MlxJacclInstance")))
      end)

      assert :ok = Exo.ensure_instance(@model, base_url: base_url)
    end

    test "places an instance and polls until it appears",
         %{bypass: bypass, base_url: base_url} do
      {:ok, agent} = Agent.start_link(fn -> false end)

      Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
        body = if Agent.get(agent, & &1), do: instances_body(@model), else: %{}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"model_id" => @model} = Jason.decode!(raw)
        Agent.update(agent, fn _ -> true end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"message" => "Command received."}))
      end)

      assert :ok =
               Exo.ensure_instance(@model,
                 base_url: base_url,
                 poll_interval_ms: 10,
                 timeout_ms: 1_000
               )
    end

    test "returns {:error, :exo_instance_unavailable} when the instance never appears",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"message" => "Command received."}))
      end)

      assert {:error, :exo_instance_unavailable} =
               Exo.ensure_instance(@model,
                 base_url: base_url,
                 poll_interval_ms: 10,
                 timeout_ms: 50
               )
    end

    test "returns {:error, :exo_unreachable} when the connection is refused" do
      assert {:error, :exo_unreachable} =
               Exo.ensure_instance(@model, base_url: "http://127.0.0.1:1")
    end

    test "returns {:error, {:http, status}} when place_instance fails",
         %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end)

      Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "Insufficient memory"}))
      end)

      assert {:error, {:http, 400}} = Exo.ensure_instance(@model, base_url: base_url)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ex_athena/chat/exo_test.exs --seed 0`
Expected: 6 new failures — `function ExAthena.Chat.Exo.ensure_instance/2 is undefined`

- [ ] **Step 3: Write the implementation**

In `lib/ex_athena/chat/exo.ex`, extend the `@moduledoc` and add below `list_models/1`:

Add to `@moduledoc` (after the existing paragraph):

```
  `ensure_instance/2` guarantees the model has an active instance before a chat
  request: exo returns 404 ("No instance found for model …") otherwise. Because
  `POST /place_instance` is NOT idempotent (it creates duplicate instances), we
  check `GET /state/instances` first and only place when absent, then poll state
  until the instance registers (sub-second in practice; weight loading happens
  after registration and only affects first-token latency).
```

Add the functions:

```elixir
  @default_poll_interval_ms 250
  @default_instance_timeout_ms 10_000

  @spec ensure_instance(String.t(), keyword()) ::
          :ok
          | {:error,
             :exo_unreachable
             | :exo_instance_unavailable
             | :unexpected_response
             | {:http, integer()}}
  def ensure_instance(model, opts \\ []) when is_binary(model) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_v1_suffix()

    case instance_active?(base, model) do
      {:ok, true} -> :ok
      {:ok, false} -> place_and_await(base, model, opts)
      {:error, _} = err -> err
    end
  end

  defp instance_active?(base, model) do
    case Req.get(base <> "/state/instances", receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_instance_presence(body, model)
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, _} -> {:error, :exo_unreachable}
    end
  end

  # Instances are a map of id => tagged union, e.g.
  # %{"<uuid>" => %{"MlxRingInstance" => %{"shardAssignments" => %{"modelId" => m}}}}.
  # The tag key varies (MlxRingInstance | MlxJacclInstance), so match any tag.
  defp decode_instance_presence(body, model) when is_map(body) do
    active? =
      Enum.any?(body, fn {_id, tagged} ->
        is_map(tagged) and
          Enum.any?(tagged, fn
            {_tag, %{"shardAssignments" => %{"modelId" => ^model}}} -> true
            _ -> false
          end)
      end)

    {:ok, active?}
  end

  defp decode_instance_presence(body, model) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_instance_presence(decoded, model)
      {:error, _} -> {:error, :unexpected_response}
    end
  end

  defp decode_instance_presence(_, _), do: {:error, :unexpected_response}

  defp place_and_await(base, model, opts) do
    url = base <> "/place_instance"

    case Req.post(url,
           json: %{"model_id" => model},
           receive_timeout: @timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} ->
        interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
        timeout = Keyword.get(opts, :timeout_ms, @default_instance_timeout_ms)
        deadline = System.monotonic_time(:millisecond) + timeout
        await_instance(base, model, interval, deadline)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, _} ->
        {:error, :exo_unreachable}
    end
  end

  defp await_instance(base, model, interval, deadline) do
    case instance_active?(base, model) do
      {:ok, true} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :exo_instance_unavailable}
        else
          Process.sleep(interval)
          await_instance(base, model, interval, deadline)
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ex_athena/chat/exo_test.exs --seed 0`
Expected: 12 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
mix format lib/ex_athena/chat/exo.ex test/ex_athena/chat/exo_test.exs
git add lib/ex_athena/chat/exo.ex test/ex_athena/chat/exo_test.exs
git commit -m "feat: add exo instance auto-activation (check-then-place, poll until ready)"
```

---

### Task 3: ContextWindow support for exo

**Files:**
- Modify: `test/ex_athena/context_window_test.exs` (append describe block)
- Modify: `lib/ex_athena/context_window.ex`

exo's `/v1/models` cards carry `context_length`. Note: lookups are cached in a
global ETS table keyed by `{backend, base_url, model}` — tests must use unique
model names (existing pattern in this test file).

- [ ] **Step 1: Write the failing tests**

Append inside `ExAthena.ContextWindowTest` (after the existing describe blocks):

```elixir
  describe "exo runtime fetch" do
    test "returns context_length from the matching model card",
         %{bypass: bypass, base_url: base_url} do
      model = "mlx-community/exo-ctx-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        body =
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{"id" => "mlx-community/other", "context_length" => 4_096},
              %{"id" => model, "context_length" => 131_072}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 131_072} =
               ContextWindow.lookup(
                 openai_compatible_backend: :exo,
                 model: model,
                 base_url: base_url
               )
    end

    test "returns :error when the card has context_length 0",
         %{bypass: bypass, base_url: base_url} do
      model = "mlx-community/exo-zero-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        body = Jason.encode!(%{"data" => [%{"id" => model, "context_length" => 0}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :exo,
                 model: model,
                 base_url: base_url
               )
    end

    test "returns :error when the model is not in the catalog",
         %{bypass: bypass, base_url: base_url} do
      model = "mlx-community/exo-missing-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        body = Jason.encode!(%{"data" => [%{"id" => "mlx-community/other", "context_length" => 8}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :exo,
                 model: model,
                 base_url: base_url
               )
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ex_athena/context_window_test.exs --seed 0`
Expected: the 3 new tests FAIL (lookup returns `:error` for the success case because the `:exo` backend is rejected by the guard — the first test fails, the other two pass vacuously; that's fine, the first test is the driver)

- [ ] **Step 3: Write the implementation**

In `lib/ex_athena/context_window.ex`:

1. Add the default near the existing module attributes (after `@llamacpp_default`):

```elixir
  @exo_default "http://localhost:52415"
```

2. Widen the guard in `lookup/1` — change:

```elixir
    with backend when backend in [:ollama, :llamacpp] <-
```

to:

```elixir
    with backend when backend in [:ollama, :llamacpp, :exo] <-
```

3. Add a `do_fetch` clause (after `do_fetch(:llamacpp, ...)`):

```elixir
  defp do_fetch(:exo, base_url, model), do: fetch_exo(base_url, model)
```

4. Add fetch + extract functions (after `extract_ollama_context/1`):

```elixir
  defp fetch_exo(base_url, model) do
    url = strip_openai_suffix(base_url) <> "/v1/models"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        extract_exo_context(body, model)

      _ ->
        :error
    end
  end

  # exo model cards carry `context_length`; 0 means unknown.
  defp extract_exo_context(%{"data" => cards}, model) when is_list(cards) do
    Enum.find_value(cards, :error, fn
      %{"id" => ^model, "context_length" => ctx} when is_integer(ctx) and ctx > 0 -> {:ok, ctx}
      _ -> nil
    end)
  end

  defp extract_exo_context(_, _), do: :error
```

5. Extend `resolve_base_url/2`'s case (add an `:exo` branch):

```elixir
  defp resolve_base_url(opts, backend) do
    default =
      case backend do
        :ollama -> configured_ollama_url()
        :llamacpp -> configured_llamacpp_url()
        :exo -> configured_exo_url()
      end

    strip_openai_suffix(Keyword.get(opts, :base_url, default))
  end
```

6. Add the config helper (after `configured_llamacpp_url/0`):

```elixir
  defp configured_exo_url do
    :ex_athena
    |> Application.get_env(:exo, [])
    |> Keyword.get(:base_url, @exo_default)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ex_athena/context_window_test.exs --seed 0`
Expected: all tests pass (existing + 3 new)

- [ ] **Step 5: Commit**

```bash
mix format lib/ex_athena/context_window.ex test/ex_athena/context_window_test.exs
git add lib/ex_athena/context_window.ex test/ex_athena/context_window_test.exs
git commit -m "feat: discover exo context windows via /v1/models cards"
```

---

### Task 4: Instance pre-flight hook in `Providers.ReqLLM`

**Files:**
- Create: `test/ex_athena/providers/req_llm_exo_test.exs`
- Modify: `lib/ex_athena/providers/req_llm.ex` (`query/2` ~line 82, `stream/3` ~line 101)

When `openai_compatible_backend: :exo`, ensure the instance before dispatching.
One hook covers web UI, TUI, and programmatic use.

- [ ] **Step 1: Write the failing tests**

Create `test/ex_athena/providers/req_llm_exo_test.exs`:

```elixir
defmodule ExAthena.Providers.ReqLLMExoTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.Message
  alias ExAthena.Providers.ReqLLM, as: Adapter
  alias ExAthena.{Error, Request, Response}

  @model "mlx-community/Llama-3.2-1B-Instruct-4bit"

  setup do
    bypass = Bypass.open()

    request = %Request{
      messages: [%Message{role: :user, content: "hi"}],
      model: @model,
      timeout_ms: 5_000
    }

    opts = [
      openai_compatible_backend: :exo,
      req_llm_provider_tag: "openai",
      base_url: "http://localhost:#{bypass.port}",
      poll_interval_ms: 10,
      timeout_ms: 50
    ]

    {:ok, bypass: bypass, request: request, opts: opts}
  end

  defp active_instances_body do
    %{
      "11111111-aaaa-bbbb-cccc-000000000001" => %{
        "MlxRingInstance" => %{
          "shardAssignments" => %{"modelId" => @model}
        }
      }
    }
  end

  test "query returns a provider error when the exo instance never becomes ready",
       %{bypass: bypass, request: request, opts: opts} do
    Bypass.expect(bypass, "GET", "/state/instances", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{}))
    end)

    Bypass.expect_once(bypass, "POST", "/place_instance", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"message" => "Command received."}))
    end)

    assert {:error, %Error{} = error} = Adapter.query(request, opts)
    assert error.message =~ "exo has no active instance"
    assert error.message =~ @model
  end

  test "query proceeds to chat completions when an instance is active",
       %{bypass: bypass, request: request, opts: opts} do
    Bypass.expect_once(bypass, "GET", "/state/instances", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(active_instances_body()))
    end)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body =
        Jason.encode!(%{
          "id" => "chatcmpl-1",
          "object" => "chat.completion",
          "created" => 1_700_000_000,
          "model" => @model,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "Hello!"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 5,
            "completion_tokens" => 2,
            "total_tokens" => 7
          }
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, %Response{} = response} = Adapter.query(request, opts)
    assert response.text == "Hello!"
  end

  test "non-exo backends skip the pre-flight entirely",
       %{bypass: bypass, request: request, opts: opts} do
    # No /state/instances or /place_instance expectations: any such request
    # would fail the test. Only the chat endpoint is stubbed.
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      body =
        Jason.encode!(%{
          "id" => "chatcmpl-2",
          "object" => "chat.completion",
          "created" => 1_700_000_000,
          "model" => @model,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    opts = Keyword.put(opts, :openai_compatible_backend, :llamacpp)
    assert {:ok, %Response{}} = Adapter.query(request, opts)
  end
end
```

(`%ExAthena.Response{}` has a `:text` field — verified in `lib/ex_athena/response.ex:14`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ex_athena/providers/req_llm_exo_test.exs --seed 0`
Expected: test 1 FAILS (no pre-flight exists, so the query goes straight to `/v1/chat/completions`, which Bypass rejects as unexpected). Tests 2 and 3 may already pass — that's expected; test 1 drives the change.

- [ ] **Step 3: Write the implementation**

In `lib/ex_athena/providers/req_llm.ex`:

1. In `query/2`, add the pre-flight to the `with` chain:

```elixir
  def query(%Request{} = request, opts) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts),
         :ok <- ensure_exo_instance(request, opts) do
```

(body unchanged otherwise)

2. Same in `stream/3`:

```elixir
  def stream(%Request{} = request, callback, opts) when is_function(callback, 1) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts),
         :ok <- ensure_exo_instance(request, opts) do
```

3. Add the private helpers (place near `resolve_api_key/2`, in the Options section):

```elixir
  # exo requires an active instance per model before chat requests succeed
  # (404 "No instance found for model …" otherwise). Activate it pre-flight;
  # ExAthena.Chat.Exo checks before placing because /place_instance is not
  # idempotent. Other backends skip this entirely.
  defp ensure_exo_instance(%Request{} = request, opts) do
    if Keyword.get(opts, :openai_compatible_backend) == :exo do
      model = raw_model_id(request, opts)

      case ExAthena.Chat.Exo.ensure_instance(model, opts) do
        :ok ->
          :ok

        {:error, :exo_unreachable} ->
          {:error,
           Error.new(:transport, "exo is unreachable at the configured base_url",
             provider: :req_llm,
             raw: :exo_unreachable
           )}

        {:error, reason} ->
          {:error,
           Error.new(
             :server_error,
             "exo has no active instance for #{model} (#{inspect(reason)})",
             provider: :req_llm,
             raw: reason
           )}
      end
    else
      :ok
    end
  end

  defp raw_model_id(%Request{model: model}, opts) when is_binary(model) and model != "",
    do: strip_tag_prefix(model, Keyword.get(opts, :req_llm_provider_tag))

  defp raw_model_id(_request, opts),
    do: strip_tag_prefix(Keyword.get(opts, :model), Keyword.get(opts, :req_llm_provider_tag))

  # Models may arrive tag-prefixed ("openai:mlx-community/..."); exo's API
  # wants the bare id.
  defp strip_tag_prefix(model, tag) when is_binary(model) and is_binary(tag) do
    prefix = tag <> ":"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end

  defp strip_tag_prefix(model, _tag), do: model
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ex_athena/providers/req_llm_exo_test.exs test/ex_athena/providers/req_llm_test.exs --seed 0`
Expected: all pass (new file + no regressions in existing adapter tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/ex_athena/providers/req_llm.ex test/ex_athena/providers/req_llm_exo_test.exs
git add lib/ex_athena/providers/req_llm.ex test/ex_athena/providers/req_llm_exo_test.exs
git commit -m "feat: auto-activate exo instances before chat requests"
```

---

### Task 5: Web UI + TUI wiring

**Files:**
- Modify: `lib/ex_athena/web/live/chat_live.ex` (`@providers` ~line 9, alias ~line 4, `fetch_models` ~line 1837, `apply_base_url` ~line 1875)
- Modify: `lib/ex_athena/chat/tui/runner.ex` (~lines 83-105)

No LiveView test infrastructure exists in this repo (no `test/ex_athena/web/`);
these are 3-line mirrors of existing untested clauses whose logic lives in the
fully-tested `Chat.Exo`. Verify by compile + existing suite + manual check.

- [ ] **Step 1: Update the alias and provider dropdown**

In `lib/ex_athena/web/live/chat_live.ex`, change:

```elixir
  alias ExAthena.Chat.{LlamaCpp, Ollama}
```

to:

```elixir
  alias ExAthena.Chat.{Exo, LlamaCpp, Ollama}
```

and add the dropdown entry after `{"Ollama", "ollama"}`:

```elixir
  @providers [
    {"llama.cpp", "llamacpp"},
    {"Ollama", "ollama"},
    {"EXO", "exo"},
    {"Claude / Anthropic", "claude"},
    {"Claude Code", "claude_code"},
    {"OpenAI-compatible", "openai_compatible"},
    {"Gemini", "gemini"}
  ]
```

- [ ] **Step 2: Add the fetch_models clause**

After the `fetch_models("ollama")` clause (before `fetch_models("claude_code")`):

```elixir
  defp fetch_models("exo") do
    base_url = Application.get_env(:ex_athena, :exo, [])[:base_url]
    opts = if base_url, do: [base_url: base_url], else: []

    case Exo.list_models(opts) do
      {:ok, models} -> models
      _ -> []
    end
  end
```

- [ ] **Step 3: Add the apply_base_url clause**

After the `apply_base_url(opts, "ollama")` clause (before the catch-all `apply_base_url(opts, _)`):

```elixir
  defp apply_base_url(opts, "exo") do
    configured = Application.get_env(:ex_athena, :exo, [])[:base_url]
    Keyword.put_new(opts, :base_url, configured || "http://localhost:52415")
  end
```

- [ ] **Step 4: Update the TUI runner**

In `lib/ex_athena/chat/tui/runner.ex`:

1. Add an `:exo` clause BEFORE the catch-all (order matters):

```elixir
  defp provider_base_url_defaults(:llamacpp), do: {:llamacpp, "http://localhost:8080"}
  defp provider_base_url_defaults(:exo), do: {:exo, "http://localhost:52415"}
  defp provider_base_url_defaults(_), do: {:ollama, "http://localhost:11434"}
```

2. Add `:exo_unreachable` to the `select_initial_model/2` spec:

```elixir
  @spec select_initial_model(String.t(), {:ok, [String.t()]} | {:error, term()}) ::
          {:ok, String.t()}
          | {:fallback, String.t()}
          | {:error,
             :no_models
             | :ollama_unreachable
             | :llamacpp_unreachable
             | :exo_unreachable
             | term()}
```

- [ ] **Step 5: Compile and run the full suite**

Run: `mix compile --warnings-as-errors && mix test --seed 0`
Expected: clean compile, all tests pass

- [ ] **Step 6: Commit**

```bash
mix format lib/ex_athena/web/live/chat_live.ex lib/ex_athena/chat/tui/runner.ex
git add lib/ex_athena/web/live/chat_live.ex lib/ex_athena/chat/tui/runner.ex
git commit -m "feat: add exo to web provider dropdown and TUI defaults"
```

---

### Task 6: Final verification

- [ ] **Step 1: Format check + full suite**

Run: `mix format --check-formatted && mix compile --force --warnings-as-errors && mix test --seed 0`
Expected: no formatting diffs, clean compile, all tests pass

- [ ] **Step 2: Manual verification (user has exo running locally)**

The dev server is already running (`mix athena.web --log`, logs in
`log/phoenix_output.log`). Phoenix hot-reloads code changes. In the browser at
the ExAthena tab:

1. Select "EXO" in the provider dropdown → model dropdown should populate with
   downloaded models (full HuggingFace ids) from `http://localhost:52415`.
2. Send a message → reply streams back; if the model had no active instance,
   the first message auto-activates it (slower first token while weights load).
3. Check `log/phoenix_output.log` for errors.

- [ ] **Step 3: Update the spec status**

In `docs/superpowers/specs/2026-06-05-exo-provider-design.md`, change
`**Status:** Approved` to `**Status:** Implemented`, then:

```bash
git add docs/superpowers/specs/2026-06-05-exo-provider-design.md
git commit -m "docs: mark exo provider spec implemented"
```

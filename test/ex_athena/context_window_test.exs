defmodule ExAthena.ContextWindowTest do
  use ExUnit.Case, async: true

  alias ExAthena.ContextWindow

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "Ollama runtime fetch" do
    test "returns context length on successful POST /api/show response",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-success-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body =
          Jason.encode!(%{
            "model_info" => %{
              "llama.context_length" => 4096
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 4096} =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url
               )
    end

    test "parses any arch key ending in .context_length",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-arch-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body =
          Jason.encode!(%{
            "model_info" => %{
              "qwen2.context_length" => 8192
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 8192} =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url
               )
    end

    test "strips /v1 suffix from base_url before hitting /api/show",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-strip-v1-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body =
          Jason.encode!(%{
            "model_info" => %{"mistral.context_length" => 32768}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 32768} =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url <> "/v1"
               )
    end

    test "returns :error on 404",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-404-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url
               )
    end

    test "returns :error on connection refused" do
      model = "ollama-fetch-refused-#{System.unique_integer([:positive])}"

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: "http://127.0.0.1:1"
               )
    end

    test "returns :error when model_info key is absent",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-no-model-info-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body = Jason.encode!(%{"other" => "data"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url
               )
    end

    test "returns :error when no .context_length key found in model_info",
         %{bypass: bypass, base_url: base_url} do
      model = "ollama-fetch-no-ctx-key-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body =
          Jason.encode!(%{
            "model_info" => %{
              "llama.some_other_field" => 42
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 model: model,
                 base_url: base_url
               )
    end
  end

  describe "llama.cpp runtime fetch" do
    test "returns n_ctx on successful GET /props response",
         %{bypass: bypass, base_url: base_url} do
      model = "llamacpp-fetch-success-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/props", fn conn ->
        body =
          Jason.encode!(%{
            "default_generation_settings" => %{
              "n_ctx" => 2048
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, 2048} =
               ContextWindow.lookup(
                 openai_compatible_backend: :llamacpp,
                 model: model,
                 base_url: base_url
               )
    end

    test "returns :error on connection refused" do
      model = "llamacpp-fetch-refused-#{System.unique_integer([:positive])}"

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :llamacpp,
                 model: model,
                 base_url: "http://127.0.0.1:1"
               )
    end

    test "returns :error when body lacks default_generation_settings.n_ctx",
         %{bypass: bypass, base_url: base_url} do
      model = "llamacpp-fetch-no-n-ctx-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "GET", "/props", fn conn ->
        body = Jason.encode!(%{"default_generation_settings" => %{"other" => 1}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :llamacpp,
                 model: model,
                 base_url: base_url
               )
    end
  end

  describe "caching" do
    test "returns cached value on second call without hitting server",
         %{bypass: bypass, base_url: base_url} do
      model = "cache-hit-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
        body =
          Jason.encode!(%{"model_info" => %{"phi3.context_length" => 16384}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      opts = [openai_compatible_backend: :ollama, model: model, base_url: base_url]

      assert {:ok, 16384} = ContextWindow.lookup(opts)
      # Second call must return cached value; Bypass.expect_once ensures only one HTTP request
      assert {:ok, 16384} = ContextWindow.lookup(opts)
    end

    test "different {backend, base_url, model} tuples are cached independently",
         %{bypass: bypass, base_url: base_url} do
      model_a = "cache-independent-a-#{System.unique_integer([:positive])}"
      model_b = "cache-independent-b-#{System.unique_integer([:positive])}"

      # Use agent to track how many requests were served
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/api/show", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        %{"model" => req_model} = Jason.decode!(raw_body)

        Agent.update(agent, &(&1 + 1))

        ctx =
          cond do
            req_model == model_a -> 1024
            req_model == model_b -> 2048
            true -> 512
          end

        body = Jason.encode!(%{"model_info" => %{"llama.context_length" => ctx}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      opts_a = [openai_compatible_backend: :ollama, model: model_a, base_url: base_url]
      opts_b = [openai_compatible_backend: :ollama, model: model_b, base_url: base_url]

      assert {:ok, 1024} = ContextWindow.lookup(opts_a)
      assert {:ok, 2048} = ContextWindow.lookup(opts_b)

      # Second calls must return cached values — server still gets only 2 total requests
      assert {:ok, 1024} = ContextWindow.lookup(opts_a)
      assert {:ok, 2048} = ContextWindow.lookup(opts_b)

      assert Agent.get(agent, & &1) == 2
    end
  end

  describe "non-local providers" do
    test "returns :error when openai_compatible_backend is not :ollama or :llamacpp" do
      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :openai,
                 model: "gpt-4",
                 base_url: "https://api.openai.com"
               )
    end

    test "returns :error when model key is missing" do
      assert :error =
               ContextWindow.lookup(
                 openai_compatible_backend: :ollama,
                 base_url: "http://localhost:11434"
               )
    end
  end
end

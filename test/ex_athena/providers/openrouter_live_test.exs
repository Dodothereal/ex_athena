defmodule ExAthena.Providers.OpenrouterLiveTest do
  use ExUnit.Case, async: false

  @moduletag :external

  test "live openrouter call returns a Response" do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")

    assert {:ok, %ExAthena.Response{} = resp} =
             ExAthena.query("ping",
               provider: :openrouter,
               base_url: "https://openrouter.ai/api/v1",
               model: "anthropic/claude-3.5-sonnet",
               api_key: api_key
             )

    assert is_binary(resp.text) and resp.text != ""
    assert resp.finish_reason in [:stop, :length]
  end
end

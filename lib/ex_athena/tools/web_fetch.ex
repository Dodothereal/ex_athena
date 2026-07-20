defmodule ExAthena.Tools.WebFetch do
  @moduledoc """
  HTTP GET via `Req`, returning the body as text.

  Arguments:

    * `url` (required) — `http://` or `https://` only; other schemes rejected.
    * `timeout_ms` (optional, default 10_000).

  Response body capped at 1 MB. Redirects followed up to 5 hops.

  ## SSRF guard

  Every fetch target — the initial URL *and* every redirect hop — is validated
  before a request is made: non-`http(s)` schemes are rejected, and hosts that
  are (or resolve to) loopback, private, link-local, CGNAT, or otherwise
  non-public addresses are refused (see `ExAthena.Net.blocked_host?/1`). This
  applies regardless of confinement, so the default library configuration
  cannot be steered to `http://169.254.169.254/` (cloud metadata),
  `localhost`, or internal services — including via a public URL that 302s to
  one. Redirects are followed manually (Req auto-redirect is disabled) so each
  `Location` target is re-validated before it is fetched.

  Hosts that legitimately need local fetching (docs served from a dev server,
  a localhost API) opt out with `allow_local_hosts: true` on `ExAthena.run/2`
  (threaded into `ctx.assigns[:allow_local_hosts]`), which disables the host
  block for that run; the scheme check still applies.

  Known limit (documented rather than over-engineered): hostname validation
  resolves DNS at check time, but the HTTP client resolves again when
  connecting, so a resolver flipping records between the two lookups
  (DNS-rebinding TOCTOU) can still slip through. Deployments that must defend
  against that should pin egress at the network layer.

  This is deliberately minimal — it's here so agents can fetch documentation
  pages, not to replace a full HTTP client. For richer access (auth headers,
  POST bodies, etc.), implement a custom tool that wraps `Req` directly.
  """

  @behaviour ExAthena.Tool

  @default_timeout 10_000
  @max_bytes 1_000_000
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  # A raw 1MB page flooded 9B workers' contexts (observed live: stream
  # timeouts + starved workers). Oversized bodies are summarized by a
  # tool-less model call when summarizer config is available, else truncated.
  @default_max_chars 20_000
  # How much of an oversized page the summarizer reads (fits a small model).
  @summary_window_chars 60_000
  @summarize_timeout_ms 600_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description,
    do:
      "GET a public URL (http/https only). Oversized pages are summarized " <>
        "(pass `query` for targeted fact extraction) or truncated to max_chars."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        url: %{type: "string"},
        timeout_ms: %{type: "integer"},
        max_chars: %{
          type: "integer",
          description: "Cap on returned content (default #{@default_max_chars})."
        },
        query: %{
          type: "string",
          description:
            "What you are looking for on the page — used to extract the relevant facts when the page is too large to return whole."
        }
      },
      required: ["url"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"url" => url} = args, ctx) when is_binary(url) do
    timeout = Map.get(args, "timeout_ms", @default_timeout)

    with {:ok, uri} <- validate_target(URI.parse(url), ctx),
         {:ok, body, status} <- fetch(uri, timeout, ctx) do
      {body, truncated?} = handle_body(body, args, ctx)

      ui = %{
        kind: :webpage,
        payload: %{
          url: URI.to_string(uri),
          status: status,
          truncated?: truncated?
        }
      }

      {:ok, body, ui}
    end
  end

  def execute(_, _), do: {:error, :missing_url}

  @doc false
  # Post-fetch overflow handling (public for tests — no network involved).
  # Returns {body, truncated?}.
  def handle_body(body, args, ctx) do
    max_chars = args |> Map.get("max_chars", @default_max_chars) |> min(@max_bytes)

    cond do
      String.length(body) <= max_chars ->
        {body, false}

      summary = summarize(body, Map.get(args, "query"), ctx) ->
        {"[summarized from #{String.length(body)} chars — refetch with max_chars for raw content]\n" <>
           summary, true}

      true ->
        marker =
          "\n\n[...truncated — page is #{String.length(body)} chars; " <>
            "refetch with max_chars or pass `query` to extract facts...]"

        {String.slice(body, 0, max_chars) <> marker, true}
    end
  end

  # Tool-less single-pass extraction through the same provider config the
  # host gives workers (flows through the GPU request queue like any call).
  # Any failure falls back to plain truncation — never breaks the fetch.
  defp summarize(body, query, ctx) do
    case Map.get(ctx.assigns || %{}, :spawn_agent_opts) do
      opts when is_list(opts) and opts != [] ->
        window = String.slice(body, 0, @summary_window_chars)

        goal =
          if is_binary(query) and query != "",
            do: "Extract every fact relevant to: #{query}",
            else: "Summarize the important facts"

        prompt =
          "#{goal}\n\nFrom this fetched web page content " <>
            "(first #{String.length(window)} of #{String.length(body)} chars):\n\n#{window}"

        run_opts =
          opts
          |> Keyword.take([:provider, :model, :base_url, :mock, :api_key, :permission_mode])
          |> Keyword.merge(
            tools: [],
            memory: false,
            conclusions: false,
            max_iterations: 1,
            timeout_ms: @summarize_timeout_ms
          )

        case ExAthena.Loop.run(prompt, run_opts) do
          {:ok, %ExAthena.Result{text: text}} when is_binary(text) and text != "" -> text
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc false
  # SSRF guard for one fetch target. The initial URL and EVERY redirect hop
  # go through here before any request is made (public for tests — the only
  # network involved is DNS resolution inside `Net.blocked_host?/1`).
  def validate_target(%URI{} = uri, ctx) do
    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_scheme, uri.scheme}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :missing_host}

      # Default-deny private/loopback/link-local hosts (localhost, internal
      # services, cloud metadata) regardless of confinement. Hosts opt out
      # per run with `allow_local_hosts: true`.
      not allow_local_hosts?(ctx) and ExAthena.Net.blocked_host?(uri.host) ->
        {:error, {:blocked_host, uri.host}}

      true ->
        {:ok, uri}
    end
  end

  defp allow_local_hosts?(ctx) do
    Map.get(ctx.assigns || %{}, :allow_local_hosts, false) == true
  end

  defp fetch(uri, timeout, ctx), do: fetch(uri, timeout, ctx, @max_redirects)

  # Redirects are followed manually (`redirect: false`) so every Location
  # target is re-validated — Req's auto-redirect would happily follow a
  # public URL 302-ing to the cloud metadata endpoint or an internal host.
  defp fetch(uri, timeout, ctx, hops_left) do
    case Req.get(URI.to_string(uri),
           receive_timeout: timeout,
           redirect: false,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: s} = resp} when s in @redirect_statuses ->
        follow_redirect(resp, uri, timeout, ctx, hops_left)

      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        body = to_binary(body)

        body =
          if byte_size(body) > @max_bytes do
            binary_part(body, 0, @max_bytes) <> "\n\n[...truncated...]"
          else
            body
          end

        {:ok, body, s}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:fetch_failed, Exception.message(exception)}}
    end
  end

  defp follow_redirect(_resp, _uri, _timeout, _ctx, 0), do: {:error, :too_many_redirects}

  defp follow_redirect(resp, uri, timeout, ctx, hops_left) do
    case Req.Response.get_header(resp, "location") do
      [location | _] ->
        with {:ok, target} <- validate_target(URI.merge(uri, location), ctx) do
          fetch(target, timeout, ctx, hops_left - 1)
        end

      [] ->
        # A redirect status without a Location is unfollowable — surface it
        # like any other non-2xx response.
        {:error, {:http_error, resp.status}}
    end
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: inspect(body)
end

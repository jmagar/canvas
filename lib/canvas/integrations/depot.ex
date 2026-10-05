defmodule Canvas.Integrations.Depot do
  @moduledoc "Search Depot skills and MCP capabilities via Labby Code Mode's live catalog."
  def search(query) do
    case Application.get_env(:canvas, :labby_mcp_url) do
      nil ->
        {:error, :depot_not_configured}

      url ->
        with {:ok, init, headers} <-
               rpc(url, [], %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "initialize",
                 "params" => %{
                   "protocolVersion" => "2025-03-26",
                   "clientInfo" => %{"name" => "canvas", "version" => "0.1.0"},
                   "capabilities" => %{}
                 }
               }),
             nil <- init["error"],
             session_headers <-
               if(headers["mcp-session-id"],
                 do: [{"mcp-session-id", List.first(headers["mcp-session-id"])}],
                 else: []
               ),
             {:ok, _, _} <-
               rpc(url, session_headers, %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/initialized"
               }),
             code <-
               "async () => { return await codemode.search({query: " <>
                 Jason.encode!(String.slice(query, 0, 1500)) <> ", limit: 8}); }",
             {:ok, result, _} <-
               rpc(url, session_headers, %{
                 "jsonrpc" => "2.0",
                 "id" => 2,
                 "method" => "tools/call",
                 "params" => %{"name" => "codemode", "arguments" => %{"code" => code}}
               }) do
          normalize(result)
        else
          _ -> {:error, :depot_discovery_failure}
        end
    end
  end

  def normalize(%{"result" => %{"isError" => true}}), do: {:error, :depot_discovery_failure}

  def normalize(%{"result" => %{"structuredContent" => %{"result" => result}}})
      when is_map(result) do
    {:ok,
     %{
       "results" => Enum.take(result["results"] || [], 8),
       "incomplete" => result["incomplete"] || false,
       "incomplete_sources" => result["incompleteSources"] || []
     }}
  end

  def normalize(_), do: {:error, :depot_contract_mismatch}

  defp rpc(url, session, payload) do
    headers =
      [{"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", "2025-03-26"}] ++
        session

    headers =
      case System.get_env("CANVAS_LABBY_TOKEN") do
        nil -> headers
        token -> [{"authorization", "Bearer " <> token} | headers]
      end

    case Req.post(url,
           headers: headers,
           json: payload,
           retry: false,
           redirect: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 202, headers: h}} ->
        {:ok, %{}, h}

      {:ok, %{status: 200, body: body, headers: h}} when is_map(body) ->
        {:ok, body, h}

      {:ok, %{status: 200, body: body, headers: h}} when is_binary(body) ->
        lines = String.split(body, "\n") |> Enum.filter(&String.starts_with?(&1, "data: "))

        decoded =
          Enum.find_value(lines, fn line ->
            case Jason.decode(String.replace_prefix(line, "data: ", "")) do
              {:ok, m} -> if m["id"], do: m
              _ -> nil
            end
          end)

        if decoded, do: {:ok, decoded, h}, else: {:error, :mcp_invalid_event_stream}

      _ ->
        {:error, :mcp_transport_failure}
    end
  end
end

defmodule Canvas.Integrations.Axon do
  @moduledoc "Bounded adapter for Axon's canonical sources and prepared-upload REST contract."
  def configured?, do: is_binary(Application.get_env(:canvas, :axon_url))

  def ingest(source, project) do
    with {:ok, target} <- target(source),
         {:ok, result} <-
           request(:post, "/v1/sources", %{
             "source" => target,
             "embed" => true,
             "scope" => if(source["url"], do: "page", else: "file"),
             "idempotency_key" => "canvas:#{project["id"]}:#{source["id"]}",
             "limits" => %{
               "max_items" => 1,
               "max_pages" => 1,
               "max_depth" => 0,
               "max_total_bytes" => 20_000_000,
               "max_chunks" => 256,
               "provider_timeout_ms" => 30_000
             },
             "output" => %{
               "json" => true,
               "response_mode" => "inline",
               "inline_limit_bytes" => 100_000,
               "artifact_mode" => "on_large_output",
               "include_progress" => false
             }
           }) do
      normalize(result)
    end
  end

  def normalize(result) do
    data = result["data"] || result

    cond do
      data["status"] not in ~w(completed completed_degraded skipped) ->
        {:error, {:axon_not_terminal, Map.take(data, ~w(job_id source_id status job))}}

      not is_map(data["counts"]) ->
        {:error, :axon_missing_counts}

      (data["counts"]["vector_points_total"] || 0) == 0 ->
        {:error, {:axon_no_vectors, Map.take(data, ~w(job_id source_id status counts))}}

      true ->
        content = get_in(data, ["inline", "content", "text"])

        {:ok,
         %{
           "receipt" =>
             Map.take(data, ~w(job_id source_id canonical_uri status counts warnings artifacts)),
           "text" => content
         }}
    end
  end

  defp target(%{"url" => url}), do: {:ok, url}

  defp target(%{"path" => path} = source) do
    with {:ok, bytes} <- File.read(path),
         {:ok, upload} <-
           request(:post, "/v1/uploads", %{
             "filename" => source["name"],
             "content_type" => "application/octet-stream",
             "size_bytes" => byte_size(bytes),
             "purpose" => "source",
             "sha256" => source["sha256"]
           }),
         id when is_binary(id) <- upload["upload_id"],
         {:ok, _} <-
           request(:put, "/v1/uploads/#{URI.encode(id)}/content", %{
             "content_ref" => %{
               "kind" => "inline_bytes",
               "bytes_base64" => Base.encode64(bytes),
               "mime_type" => "application/octet-stream"
             },
             "sha256" => source["sha256"]
           }),
         {:ok, completed} <-
           request(:post, "/v1/uploads/#{URI.encode(id)}/complete", %{
             "sha256" => source["sha256"]
           }),
         ref when is_binary(ref) <- completed["source_ref"] do
      {:ok, ref}
    else
      {:error, why} -> {:error, why}
      _ -> {:error, :axon_upload_contract_mismatch}
    end
  end

  defp request(method, path, body) do
    base = Application.get_env(:canvas, :axon_url)

    opts = [
      method: method,
      url: String.trim_trailing(base, "/") <> path,
      json: body,
      retry: false,
      redirect: false,
      receive_timeout: 60_000,
      connect_options: [timeout: 5_000]
    ]

    opts =
      case System.get_env("CANVAS_AXON_TOKEN") do
        nil -> opts
        token -> Keyword.put(opts, :auth, {:bearer, token})
      end

    case Req.request(opts) do
      {:ok, %{status: status, body: response}}
      when status in [200, 201, 202] and is_map(response) ->
        {:ok, response["data"] || response}

      {:ok, %{status: status}} ->
        {:error, {:axon_http_status, status}}

      {:error, _} ->
        {:error, :axon_transport_failure}
    end
  end
end

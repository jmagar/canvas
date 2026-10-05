defmodule Canvas.Agents do
  @moduledoc "Coordinates durable node state with supervised app-server sessions."
  alias Canvas.{Store, Context}
  alias Canvas.Codex.Session

  def chat(id, text, opts \\ []) do
    case Store.get(id) do
      nil ->
        {:error, :not_found}

      %{"status" => status} when status in ~w(starting running) ->
        {:error, :already_running}

      node ->
        if String.trim(text) == "" do
          {:error, :empty_message}
        else
          Store.message(id, "user", String.slice(text, 0, 20_000))
          Store.update(id, %{"status" => "starting"})

          async(id, fn ->
            with true <- File.dir?(Context.workspace(node)) || {:error, :repository_not_found},
                 {:ok, _} <- Session.ensure(node),
                 {:ok, thread} <- thread(node),
                 _ <- Store.update(id, %{"thread_id" => thread}),
                 {:ok, _result} <-
                   Session.request(
                     id,
                     "turn/start",
                     Map.merge(
                       %{
                         "threadId" => thread,
                         "model" => model(id),
                         "input" => Context.input(node, text)
                       },
                       if(opts[:output_schema],
                         do: %{"outputSchema" => opts[:output_schema]},
                         else: %{}
                       )
                     )
                   ) do
              :ok
            end
          end)

          :ok
        end
    end
  end

  def dispatch(id, text) do
    parent = Store.get(id)

    node =
      Store.create(%{
        "kind" => "agent",
        "title" => String.slice(text, 0, 80),
        "description" => text,
        "repo" => parent["repo"],
        "parent_id" => id,
        "x" => parent["x"] + 360,
        "y" => parent["y"] + 260
      })

    if Application.get_env(:canvas, :vm_runner) do
      chat(node["id"], text)
    else
      Store.update(node["id"], %{"status" => "blocked"})

      Store.message(
        node["id"],
        "system",
        "Task saved. Configure CANVAS_VM_RUNNER to connect a Microsandbox-isolated app-server. No agent has been launched on the host."
      )
    end

    node["id"]
  end

  def steer(id, text) do
    node = Store.get(id)

    if node["turn_id"] && String.trim(text) != "" do
      Store.message(id, "user", text)

      async(id, fn ->
        Session.request(id, "turn/steer", %{
          "threadId" => node["thread_id"],
          "expectedTurnId" => node["turn_id"],
          "input" => Context.input(node, text)
        })
      end)

      :ok
    else
      {:error, :no_active_turn}
    end
  end

  def interrupt(id) do
    node = Store.get(id)

    if node["turn_id"] do
      async(id, fn ->
        Session.request(id, "turn/interrupt", %{
          "threadId" => node["thread_id"],
          "turnId" => node["turn_id"]
        })
      end)

      :ok
    else
      {:error, :no_active_turn}
    end
  end

  def sessions(id) do
    node = Store.get(id)

    with {:ok, _} <- Session.ensure(node) do
      Session.request(id, "thread/list", %{"limit" => 30, "sortKey" => "updated_at"})
    end
  end

  def import_session(id, thread_id) do
    with {:ok, result} <-
           Session.request(id, "thread/read", %{"threadId" => thread_id, "includeTurns" => true}) do
      text = Jason.encode!(result["thread"])
      path = Path.join(Context.project_dir(id), Store.id() <> ".json")
      File.write!(path, text)
      File.chmod!(path, 0o600)

      Store.attach(id, %{
        "kind" => "session",
        "name" => "Codex session #{thread_id}",
        "path" => path,
        "size" => byte_size(text)
      })

      :ok
    end
  end

  defp thread(%{"thread_id" => nil} = node) do
    params = %{
      "model" => model(node["id"]),
      "cwd" => Context.workspace(node),
      "sandbox" => "read-only",
      "approvalPolicy" => "never",
      "ephemeral" => false
    }

    with {:ok, result} <- Session.request(node["id"], "thread/start", params),
         do: {:ok, result["thread"]["id"]}
  end

  defp thread(node) do
    with {:ok, _} <-
           Session.request(node["id"], "thread/resume", %{
             "threadId" => node["thread_id"],
             "model" => model(node["id"]),
             "cwd" => Context.workspace(node),
             "sandbox" => "read-only",
             "approvalPolicy" => "never"
           }),
         do: {:ok, node["thread_id"]}
  end

  defp model(id) do
    case System.get_env("CANVAS_CODEX_MODEL") do
      nil ->
        case Session.request(id, "model/list", %{}) do
          {:ok, %{"data" => models}} ->
            case Enum.find(models, & &1["isDefault"]) do
              nil -> nil
              item -> item["model"]
            end

          _ ->
            nil
        end

      value ->
        value
    end
  end

  defp async(id, fun) do
    Task.Supervisor.start_child(Canvas.Tasks, fn ->
      result =
        try do
          fun.()
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:error, reason} ->
          Store.update(id, %{"status" => "failed", "turn_id" => nil})
          Store.message(id, "system", "Codex request failed: #{inspect(reason, limit: 10)}")
          Canvas.Ingestion.agent_completed(id)

        _ ->
          :ok
      end
    end)
  end
end

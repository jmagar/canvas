defmodule Canvas.Codex.Session do
  @moduledoc "One supervised JSON-RPC stdio app-server per canvas item. No shell interpolation."
  use GenServer
  alias Canvas.Store
  def start_link(node), do: GenServer.start_link(__MODULE__, node, name: via(node["id"]))

  def child_spec(node),
    do: %{id: node["id"], start: {__MODULE__, :start_link, [node]}, restart: :temporary}

  def via(id), do: {:via, Registry, {Canvas.Codex.Registry, id}}
  def request(id, method, params), do: GenServer.call(via(id), {:request, method, params}, 65_000)

  def ensure(node) do
    case Registry.lookup(Canvas.Codex.Registry, node["id"]) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(Canvas.Codex.Supervisor, {__MODULE__, node})
    end
  end

  @impl true
  def init(node) do
    Process.flag(:trap_exit, true)

    with {:ok, executable, args} <- transport(node) do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:cd, String.to_charlist(Canvas.Context.workspace(node))}
        ])

      {:ok,
       %{
         port: port,
         node_id: node["id"],
         buffer: "",
         next_id: 1,
         pending: %{},
         ready: false,
         waiting: []
       }, {:continue, :initialize}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp transport(%{"kind" => "agent"}) do
    case Application.get_env(:canvas, :vm_runner) do
      nil ->
        {:error, :vm_runner_not_configured}

      runner ->
        if File.regular?(runner),
          do: {:ok, runner, ["app-server", "--stdio"]},
          else: {:error, :vm_runner_not_found}
    end
  end

  defp transport(_) do
    case System.find_executable(Application.get_env(:canvas, :codex_binary, "codex")) do
      nil -> {:error, :codex_not_found}
      executable -> {:ok, executable, ["app-server", "--stdio"]}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    {:noreply,
     send_request(state, :initialize, "initialize", %{
       "clientInfo" => %{"name" => "canvas", "version" => "0.1.0"}
     })}
  end

  @impl true
  def handle_call({:request, method, params}, from, %{ready: false} = state) do
    {:noreply, %{state | waiting: state.waiting ++ [{from, method, params}]}}
  end

  def handle_call({:request, method, params}, from, state),
    do: {:noreply, send_request(state, from, method, params)}

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    buffer = state.buffer <> bytes

    if byte_size(buffer) > 8_000_000 do
      {:stop, :protocol_buffer_overflow, state}
    else
      lines = :binary.split(buffer, "\n", [:global])
      {complete, [tail]} = Enum.split(lines, -1)

      next =
        Enum.reduce(complete, %{state | buffer: tail}, fn line, acc ->
          case Jason.decode(line) do
            {:ok, msg} -> receive_message(msg, acc)
            _ -> acc
          end
        end)

      {:noreply, next}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:stop, {:app_server_exit, code}, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:stop, {:app_server_exit, reason}, state}

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{:initialize, _timer}, _} ->
        {:stop, :initialize_timeout, state}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp send_request(state, from, method, params) do
    id = state.next_id
    send_json(state.port, %{"id" => id, "method" => method, "params" => params})
    timer = Process.send_after(self(), {:timeout, id}, 60_000)
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, {from, timer})}
  end

  defp send_json(port, msg), do: Port.command(port, Jason.encode!(msg) <> "\n")

  defp receive_message(%{"id" => id, "method" => method}, state) do
    # Unsupported approvals/tool requests fail explicitly; never silently accept them.
    send_json(state.port, %{
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Canvas spike cannot handle #{method}; request denied"
      }
    })

    Store.activity(state.node_id, "Request requires unsupported interaction: #{method}")
    state
  end

  defp receive_message(%{"id" => id} = msg, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        result = if msg["error"], do: {:error, msg["error"]}, else: {:ok, msg["result"]}
        state = %{state | pending: pending}

        case {from, result} do
          {:initialize, {:ok, _}} ->
            send_json(state.port, %{"method" => "initialized"})
            Store.activity(state.node_id, "Codex app-server connected")

            Enum.reduce(state.waiting, %{state | ready: true, waiting: []}, fn {f, m, p}, acc ->
              send_request(acc, f, m, p)
            end)

          {:initialize, {:error, error}} ->
            Enum.each(state.waiting, fn {f, _, _} -> GenServer.reply(f, {:error, error}) end)
            Store.activity(state.node_id, "Initialization failed: #{inspect(error)}")
            %{state | waiting: []}

          _ ->
            GenServer.reply(from, result)
            state
        end
    end
  end

  defp receive_message(%{"method" => method, "params" => params}, state) do
    event(state.node_id, method, params)
    state
  end

  defp receive_message(_, state), do: state

  defp event(id, "item/agentMessage/delta", p), do: Store.delta(id, p["itemId"], p["delta"] || "")

  defp event(id, "turn/started", p),
    do: Store.update(id, %{"status" => "running", "turn_id" => p["turn"]["id"]})

  defp event(id, "turn/completed", p) do
    turn = p["turn"]
    Store.update(id, %{"status" => turn["status"] || "completed", "turn_id" => nil})
    Store.activity(id, "Turn #{turn["status"]}")
    Canvas.Ingestion.agent_completed(id)
    if turn["error"], do: Store.message(id, "system", inspect(turn["error"]))
  end

  defp event(id, "item/started", p), do: Store.activity(id, "Started #{p["item"]["type"]}")

  defp event(id, "item/completed", %{
         "item" => %{"type" => "agentMessage", "id" => item_id, "text" => text}
       }) do
    Store.change(id, fn n ->
      msgs =
        Enum.reject(n["messages"], &(&1["id"] == item_id)) ++
          [%{"id" => item_id, "role" => "assistant", "text" => String.slice(text, 0, 100_000)}]

      Map.put(n, "messages", Enum.take(msgs, -100))
    end)
  end

  defp event(id, "item/completed", p), do: Store.activity(id, "Completed #{p["item"]["type"]}")

  defp event(id, "error", p),
    do: Store.message(id, "system", p["error"]["message"] || "App-server error")

  defp event(_, _, _), do: :ok

  @impl true
  def terminate(reason, state) do
    Enum.each(state.pending, fn {_, {from, timer}} ->
      Process.cancel_timer(timer)
      if from != :initialize, do: GenServer.reply(from, {:error, :app_server_disconnected})
    end)

    Enum.each(state.waiting, fn {from, _, _} ->
      GenServer.reply(from, {:error, :app_server_disconnected})
    end)

    if Store.get(state.node_id) do
      node = Store.get(state.node_id)

      if node["status"] in ~w(starting running),
        do: Store.update(state.node_id, %{"status" => "interrupted", "turn_id" => nil})

      Store.activity(state.node_id, "App-server disconnected: #{inspect(reason)}")
    end

    try do
      Port.close(state.port)
    catch
      _, _ -> :ok
    end
  end
end

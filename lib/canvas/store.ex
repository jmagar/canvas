defmodule Canvas.Store do
  @moduledoc "Single-owner spike store. Serialized mutations, atomic JSON snapshots and PubSub updates."
  use GenServer
  @kinds ~w(idea issue task pr agent)
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def get(id), do: Enum.find(snapshot().nodes, &(&1["id"] == id))
  def mutate(fun, server \\ __MODULE__), do: GenServer.call(server, {:mutate, fun})
  def subscribe, do: Phoenix.PubSub.subscribe(Canvas.PubSub, "canvas:local")
  def data_dir, do: Application.fetch_env!(:canvas, :data_dir)
  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  def create(attrs) do
    mutate(fn state ->
      kind = if attrs["kind"] in @kinds, do: attrs["kind"], else: "idea"

      node = %{
        "id" => id(),
        "kind" => kind,
        "title" => String.slice(attrs["title"] || "Untitled idea", 0, 160),
        "description" => attrs["description"] || "",
        "repo" => attrs["repo"] || "",
        "status" => "idle",
        "x" => attrs["x"] || 100 + rem(length(state.nodes), 4) * 420,
        "y" => attrs["y"] || 100 + div(length(state.nodes), 4) * 380,
        "attachments" => [],
        "messages" => [],
        "activity" => [],
        "thread_id" => nil,
        "turn_id" => nil,
        "parent_id" => attrs["parent_id"],
        "created_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      edges =
        if node["parent_id"],
          do:
            state.edges ++
              [
                %{
                  "id" => id(),
                  "from" => node["parent_id"],
                  "to" => node["id"],
                  "label" => "dispatches"
                }
              ],
          else: state.edges

      {node, %{state | nodes: state.nodes ++ [node], edges: edges}}
    end)
  end

  def update(id, attrs) do
    change(
      id,
      &Map.merge(&1, Map.take(attrs, ~w(title description repo x y status thread_id turn_id)))
    )
  end

  def change(id, fun) do
    mutate(fn state ->
      case Enum.find(state.nodes, &(&1["id"] == id)) do
        nil ->
          {{:error, :not_found}, state}

        node ->
          updated = fun.(node)

          {updated,
           %{
             state
             | nodes: Enum.map(state.nodes, fn n -> if n["id"] == id, do: updated, else: n end)
           }}
      end
    end)
  end

  def attach(node_id, attachment) do
    attachment =
      attachment
      |> Map.put_new("id", id())
      |> Map.put_new("classification", Canvas.Classifier.pending())
      |> Map.put_new("ingestion", %{"status" => "queued", "reason" => "Waiting for ingestion"})

    result = change(node_id, &Map.update!(&1, "attachments", fn a -> a ++ [attachment] end))
    if Process.whereis(Canvas.Ingestion), do: Canvas.Ingestion.enqueue(node_id, attachment["id"])
    result
  end

  def message(id, role, text),
    do:
      change(
        id,
        &Map.update!(&1, "messages", fn a ->
          Enum.take(a ++ [%{"id" => id(), "role" => role, "text" => text}], -100)
        end)
      )

  def activity(id, text),
    do:
      change(
        id,
        &Map.update!(&1, "activity", fn a ->
          Enum.take(a ++ [%{"id" => id(), "text" => String.slice(text, 0, 2000)}], -50)
        end)
      )

  def delta(id, item, text) do
    change(id, fn node ->
      msgs = node["messages"]

      msgs =
        if Enum.any?(msgs, &(&1["id"] == item)),
          do:
            Enum.map(msgs, fn m ->
              if m["id"] == item,
                do: Map.update!(m, "text", &String.slice(&1 <> text, 0, 100_000)),
                else: m
            end),
          else:
            msgs ++
              [%{"id" => item, "role" => "assistant", "text" => String.slice(text, 0, 100_000)}]

      Map.put(node, "messages", Enum.take(msgs, -100))
    end)
  end

  def connect(from, to) do
    mutate(fn state ->
      valid =
        from != to and
          Enum.all?([from, to], fn id ->
            Enum.any?(state.nodes, fn n ->
              n["id"] == id or Enum.any?(n["attachments"], &("source-" <> &1["id"] == id))
            end)
          end)

      exists = Enum.any?(state.edges, &(&1["from"] == from and &1["to"] == to))

      if valid and not exists do
        edge = %{"id" => id(), "from" => from, "to" => to, "label" => "relates to"}
        {:ok, %{state | edges: state.edges ++ [edge]}}
      else
        {{:error, :invalid_edge}, state}
      end
    end)
  end

  def delete(id) do
    mutate(fn state ->
      {:ok,
       %{
         state
         | nodes: Enum.reject(state.nodes, &(&1["id"] == id)),
           edges: Enum.reject(state.edges, &(&1["from"] == id or &1["to"] == id))
       }}
    end)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Path.join(data_dir(), "board.json"))
    File.mkdir_p!(Path.dirname(path))

    state =
      case File.read(path) do
        {:ok, json} ->
          %{"nodes" => nodes, "edges" => edges} = Jason.decode!(json)
          # An app restart is not proof of live agent execution.
          nodes =
            Enum.map(nodes, fn n ->
              if n["status"] in ~w(running starting),
                do: Map.merge(n, %{"status" => "interrupted", "turn_id" => nil}),
                else: n
            end)

          %{nodes: nodes, edges: edges}

        {:error, :enoent} ->
          seed()

        {:error, reason} ->
          raise "Cannot read canvas store: #{inspect(reason)}"
      end

    {:ok, Map.put(state, :path, path)}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, Map.take(state, [:nodes, :edges]), state}

  def handle_call({:mutate, fun}, _, state) do
    {result, next} = fun.(state)
    json = Jason.encode!(Map.take(next, [:nodes, :edges]))
    :ok = File.write(next.path <> ".tmp", json)
    :ok = File.chmod(next.path <> ".tmp", 0o600)
    :ok = File.rename(next.path <> ".tmp", next.path)
    Phoenix.PubSub.broadcast(Canvas.PubSub, "canvas:local", :board_changed)
    {:reply, result, next}
  end

  defp seed do
    nodes =
      [
        %{
          "id" => "welcome",
          "kind" => "idea",
          "title" => "Your next big idea",
          "description" =>
            "A place to think, gather context, and build with agents. Select a card to describe your goal, attach source material, and open a dedicated Codex conversation.",
          "x" => 120,
          "y" => 180
        },
        %{
          "id" => "context",
          "kind" => "task",
          "title" => "Give your idea context",
          "description" =>
            "Attach documents and images, add reference links, and point to a local repository. Each conversation receives a fresh, bounded context manifest.",
          "x" => 500,
          "y" => 100
        },
        %{
          "id" => "agents",
          "kind" => "task",
          "title" => "Make the work visible",
          "description" =>
            "Dispatch a task to create a linked agent card. Follow its real app-server activity, interrupt a turn, or send a steering message. VM dispatch requires a configured isolated runner.",
          "x" => 500,
          "y" => 390
        }
      ]
      |> Enum.map(
        &Map.merge(
          %{
            "repo" => "",
            "status" => "idle",
            "attachments" => [],
            "messages" => [],
            "activity" => [],
            "thread_id" => nil,
            "turn_id" => nil,
            "parent_id" => nil,
            "created_at" => ""
          },
          &1
        )
      )

    %{
      nodes: nodes,
      edges: [
        %{"id" => "e1", "from" => "welcome", "to" => "context", "label" => "informs"},
        %{"id" => "e2", "from" => "welcome", "to" => "agents", "label" => "dispatches"}
      ]
    }
  end
end

defmodule CanvasWeb.CanvasLive do
  use CanvasWeb, :live_view
  alias Canvas.{Store, Agents}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Store.subscribe()

    socket =
      socket
      |> assign(
        page_title: "Canvas",
        sidebar_open: false,
        selected_id: "welcome",
        tab: "context",
        modal: nil,
        filter: "all",
        query: "",
        sessions: [],
        sessions_loading: false,
        create_form: to_form(%{"title" => "", "kind" => "idea"}, as: :node),
        link_form: to_form(%{"url" => "", "name" => ""}, as: :link),
        chat_form: to_form(%{"text" => "", "mode" => "chat"}, as: :chat),
        connect_form: to_form(%{"target" => ""}, as: :edge)
      )
      |> stream_configure(:messages, dom_id: fn msg -> "message-#{msg["id"]}" end)
      |> allow_upload(:context, accept: :any, max_entries: 10, max_file_size: 20_000_000)
      |> refresh()

    {:ok, socket}
  end

  defp refresh(socket) do
    board = Store.snapshot()
    selected = Enum.find(board.nodes, &(&1["id"] == socket.assigns.selected_id))

    nodes =
      Enum.filter(board.nodes, fn n ->
        (socket.assigns.filter == "all" or n["kind"] == socket.assigns.filter) and
          String.contains?(String.downcase(n["title"]), String.downcase(socket.assigns.query))
      end)

    source_nodes =
      for n <- nodes, {a, i} <- Enum.with_index(n["attachments"]) do
        %{
          "id" => "source-" <> a["id"],
          "kind" => "reference",
          "title" => a["name"],
          "description" =>
            get_in(a, ["reference", "summary"]) || a["url"] || "Attached source material",
          "parent_id" => n["id"],
          "status" => get_in(a, ["ingestion", "status"]) || "queued",
          "x" => a["x"] || n["x"] - 330,
          "y" => a["y"] || n["y"] + i * 220,
          "attachments" => [],
          "messages" => []
        }
      end

    source_edges =
      for n <- nodes, a <- n["attachments"] do
        %{
          "id" => "belongs-" <> a["id"],
          "from" => "source-" <> a["id"],
          "to" => n["id"],
          "label" => "informs"
        }
      end

    reference_text =
      case selected && selected["reference_document"] do
        %{"path" => path} ->
          case File.read(path) do
            {:ok, text} -> String.slice(text, 0, 50_000)
            _ -> ""
          end

        _ ->
          ""
      end

    edit_form =
      if socket.assigns[:selected] && selected && socket.assigns.selected["id"] == selected["id"],
        do: socket.assigns.edit_form,
        else:
          to_form(if(selected, do: Map.take(selected, ~w(title description repo)), else: %{}),
            as: :project
          )

    graph = %{
      nodes:
        source_nodes ++
          Enum.map(
            nodes,
            &Map.take(&1, ~w(id kind title description x y status attachments messages))
          ),
      edges: board.edges ++ source_edges,
      selected: socket.assigns.selected_id
    }

    socket
    |> assign(
      board: board,
      selected: selected,
      visible_nodes: nodes,
      graph_json: Jason.encode!(graph),
      reference_text: reference_text,
      active_count: Enum.count(board.nodes, &(&1["status"] in ~w(starting running))),
      edit_form: edit_form
    )
    |> stream(:messages, if(selected, do: selected["messages"], else: []), reset: true)
  end

  @impl true
  def handle_info(:board_changed, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("toggle_sidebar", _, socket),
    do: {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, socket |> assign(selected_id: id, sessions: []) |> refresh()}
  end

  def handle_event("tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, tab: tab)}

  def handle_event("modal", %{"name" => name}, socket),
    do: {:noreply, assign(socket, modal: name)}

  def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("close_inspector", _, socket),
    do: {:noreply, socket |> assign(selected_id: nil) |> refresh()}

  def handle_event("filter", %{"kind" => kind}, socket),
    do: {:noreply, socket |> assign(filter: kind) |> refresh()}

  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, socket |> assign(query: query) |> refresh()}

  def handle_event("create", %{"node" => attrs}, socket) do
    if String.trim(attrs["title"]) == "" do
      {:noreply, put_flash(socket, :error, "Give your item a title.")}
    else
      node = Store.create(attrs)
      {:noreply, socket |> assign(selected_id: node["id"], modal: nil) |> refresh()}
    end
  end

  def handle_event("edit_context", %{"project" => attrs}, socket),
    do: {:noreply, assign(socket, edit_form: to_form(attrs, as: :project))}

  def handle_event("retry_ingestion", _, socket) do
    Canvas.Ingestion.retry(socket.assigns.selected_id)

    {:noreply,
     put_flash(socket, :info, "Ingestion queued. Configured services will run the pipeline.")}
  end

  def handle_event("discover_capabilities", _, socket) do
    id = socket.assigns.selected_id
    {:noreply, start_async(socket, :capabilities, fn -> Canvas.Ingestion.discover(id) end)}
  end

  def handle_event("accept_relation", %{"from" => from, "to" => to}, socket) do
    Store.connect("source-" <> from, "source-" <> to)
    {:noreply, refresh(socket)}
  end

  def handle_event("save", %{"project" => attrs}, socket) do
    Store.update(
      socket.assigns.selected_id,
      Map.new(attrs, fn {k, v} -> {k, String.slice(v, 0, 20_000)} end)
    )

    {:noreply,
     socket
     |> assign(edit_form: to_form(attrs, as: :project))
     |> refresh()
     |> put_flash(:info, "Project context saved.")}
  end

  def handle_event("move", %{"id" => "source-" <> source_id, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    owner =
      Enum.find(socket.assigns.board.nodes, fn n ->
        Enum.any?(n["attachments"], &(&1["id"] == source_id))
      end)

    if owner do
      Store.change(owner["id"], fn n ->
        Map.update!(n, "attachments", fn a ->
          Enum.map(a, fn item ->
            if item["id"] == source_id,
              do: Map.merge(item, %{"x" => round(x), "y" => round(y)}),
              else: item
          end)
        end)
      end)
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("move", %{"id" => id, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    Store.update(id, %{
      "x" => min(max(round(x), -5000), 5000),
      "y" => min(max(round(y), -5000), 5000)
    })

    {:noreply, refresh(socket)}
  end

  def handle_event("move", _, socket), do: {:noreply, socket}

  def handle_event("add_link", %{"link" => attrs}, socket) do
    uri = URI.parse(attrs["url"])

    if uri.scheme in ~w(http https) and is_binary(uri.host) and uri.host != "" do
      Store.attach(socket.assigns.selected_id, %{
        "kind" => "link",
        "name" => if(attrs["name"] == "", do: uri.host, else: attrs["name"]),
        "url" => attrs["url"]
      })

      {:noreply, socket |> assign(modal: nil) |> refresh()}
    else
      {:noreply, put_flash(socket, :error, "Enter a complete http or https link.")}
    end
  end

  def handle_event("validate_upload", _, socket), do: {:noreply, socket}

  def handle_event("upload", _, socket) do
    id = socket.assigns.selected_id

    consume_uploaded_entries(socket, :context, fn %{path: path}, entry ->
      attachment = Canvas.Context.save_upload(id, path, entry.client_name)
      Store.attach(id, attachment)
      {:ok, attachment}
    end)

    {:noreply, socket |> assign(modal: nil) |> refresh()}
  end

  def handle_event("classify", _, socket) do
    case Canvas.Classifier.classify(socket.assigns.selected_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Classifying source material.")}

      {:error, :decision_model_not_configured} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Configure TYPESAFE_API_KEY for Jev, or Cloudflare credentials for CLEF. Classification remains pending."
         )}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :context, ref)}

  def handle_event("send", %{"chat" => %{"text" => text, "mode" => mode}}, socket) do
    id = socket.assigns.selected_id

    cond do
      String.trim(text) == "" ->
        {:noreply, put_flash(socket, :error, "Describe what you want Codex to do.")}

      mode == "dispatch" ->
        child = Agents.dispatch(id, text)

        {:noreply,
         socket
         |> assign(
           selected_id: child,
           tab: "conversation",
           chat_form: to_form(%{"text" => "", "mode" => "chat"}, as: :chat)
         )
         |> refresh()}

      true ->
        result =
          if socket.assigns.selected["turn_id"],
            do: Agents.steer(id, text),
            else: Agents.chat(id, text)

        case result do
          :ok ->
            {:noreply,
             socket
             |> assign(chat_form: to_form(%{"text" => "", "mode" => "chat"}, as: :chat))
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Cannot send: #{reason}")}
        end
    end
  end

  def handle_event("interrupt", _, socket) do
    Agents.interrupt(socket.assigns.selected_id)
    {:noreply, socket}
  end

  def handle_event("connect", %{"edge" => %{"target" => target}}, socket) do
    Store.connect(socket.assigns.selected_id, target)
    {:noreply, socket |> assign(modal: nil) |> refresh()}
  end

  def handle_event("delete", _, socket) do
    if socket.assigns.selected["status"] in ~w(starting running) do
      {:noreply,
       put_flash(socket, :error, "Interrupt the active turn before removing this item.")}
    else
      Store.delete(socket.assigns.selected_id)
      {:noreply, socket |> assign(selected_id: nil, modal: nil) |> refresh()}
    end
  end

  def handle_event("load_sessions", _, socket) do
    id = socket.assigns.selected_id

    {:noreply,
     socket
     |> assign(sessions_loading: true)
     |> start_async(:sessions, fn -> {id, Agents.sessions(id)} end)}
  end

  def handle_event("import_session", %{"id" => thread_id}, socket) do
    id = socket.assigns.selected_id

    {:noreply,
     start_async(socket, :import_session, fn -> Agents.import_session(id, thread_id) end)}
  end

  @impl true
  def handle_async(:capabilities, {:ok, _}, socket), do: {:noreply, refresh(socket)}

  def handle_async(:capabilities, _, socket),
    do: {:noreply, put_flash(socket, :error, "Capability discovery failed.")}

  def handle_async(:sessions, {:ok, {id, {:ok, result}}}, socket) do
    if id == socket.assigns.selected_id do
      {:noreply, assign(socket, sessions: result["data"] || [], sessions_loading: false)}
    else
      {:noreply, assign(socket, sessions_loading: false)}
    end
  end

  def handle_async(:sessions, _, socket),
    do:
      {:noreply,
       socket
       |> assign(sessions_loading: false)
       |> put_flash(
         :error,
         "Session discovery failed. Check Codex authentication and app-server availability."
       )}

  def handle_async(:import_session, {:ok, :ok}, socket),
    do:
      {:noreply, socket |> refresh() |> put_flash(:info, "Session attached to project context.")}

  def handle_async(:import_session, _, socket),
    do: {:noreply, put_flash(socket, :error, "Could not import session.")}

  defp kind_icon("idea"), do: "hero-light-bulb"
  defp kind_icon("issue"), do: "hero-exclamation-circle"
  defp kind_icon("pr"), do: "hero-code-bracket"
  defp kind_icon("agent"), do: "hero-cpu-chip"
  defp kind_icon(_), do: "hero-check-circle"
  defp attachment_icon("link"), do: "hero-link"
  defp attachment_icon("image"), do: "hero-photo"
  defp attachment_icon("session"), do: "hero-chat-bubble-left-right"
  defp attachment_icon(_), do: "hero-document-text"
end

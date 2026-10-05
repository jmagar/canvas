defmodule CanvasWeb.CanvasLiveTest do
  use CanvasWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Canvas.Store

  test "create, edit and select keep project context scoped", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#new-item") |> render_click()

    view
    |> form("#create-form", node: %{title: "Test isolated idea", kind: "idea"})
    |> render_submit()

    node = Enum.find(Store.snapshot().nodes, &(&1["title"] == "Test isolated idea"))

    view
    |> form("#context-form",
      project: %{title: "Renamed idea", description: "Private outcome", repo: ""}
    )
    |> render_submit()

    assert Store.get(node["id"])["description"] == "Private outcome"
    assert has_element?(view, "#project-#{node["id"]}", "Renamed idea")
    view |> element("#project-context") |> render_click()
    refute Store.get("context")["description"] == "Private outcome"
    refute has_element?(view, "#project_description", "Private outcome")
  end

  test "links validate schemes and become pending classified sources", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("button[aria-label='Add link']") |> render_click()

    view
    |> form("#link-form", link: %{url: "javascript:alert(1)", name: "bad"})
    |> render_submit()

    refute Enum.any?(Store.get("welcome")["attachments"], &(&1["name"] == "bad"))

    view
    |> form("#link-form", link: %{url: "https://example.com/spec", name: "Spec"})
    |> render_submit()

    assert has_element?(view, "a[href='https://example.com/spec']", "Spec")
    source = Enum.find(Store.get("welcome")["attachments"], &(&1["name"] == "Spec"))
    assert source["classification"]["status"] == "pending"
    assert has_element?(view, "#classify-sources")
  end

  test "upload stores bytes privately and exposes a download", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("button[aria-label='Upload files']") |> render_click()

    upload =
      file_input(view, "#upload-form", :context, [
        %{name: "spec.txt", content: "Only this project", type: "text/plain"}
      ])

    assert render_upload(upload, "spec.txt") =~ "spec.txt"
    view |> form("#upload-form") |> render_submit()
    source = Enum.find(Store.get("welcome")["attachments"], &(&1["name"] == "spec.txt"))
    assert File.read!(source["path"]) == "Only this project"

    assert source["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, "Only this project"), case: :lower)

    response = get(conn, "/attachments/welcome/#{source["id"]}")
    assert response.status == 200
    assert response.resp_body == "Only this project"
    assert get(conn, "/attachments/context/#{source["id"]}").status == 404
  end

  test "dispatch shows a blocked graph node without host execution", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element(".inspector-tabs button[phx-value-tab='conversation']") |> render_click()

    view
    |> form("#chat-form", chat: %{text: "Build a VM worker", mode: "dispatch"})
    |> render_submit()

    node = Enum.find(Store.snapshot().nodes, &(&1["title"] == "Build a VM worker"))
    assert node["status"] == "blocked"
    assert node["parent_id"] == "welcome"

    assert Enum.any?(
             Store.snapshot().edges,
             &(&1["to"] == node["id"] and &1["from"] == "welcome")
           )

    assert Registry.lookup(Canvas.Codex.Registry, node["id"]) == []
    assert has_element?(view, "#messages .message.system")
  end

  test "coordinates and edges survive a fresh connection", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render_hook(view, "move", %{id: "welcome", x: 342, y: 456})
    assert Store.get("welcome")["x"] == 342
    {:ok, fresh, _} = live(conn, "/")
    graph = fresh |> element("#spatial-canvas") |> render()
    assert graph =~ "342"
  end
end

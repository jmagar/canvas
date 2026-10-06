defmodule CanvasWeb.PreviewTest do
  use CanvasWeb.ConnCase, async: false

  test "image previews sniff allowed formats and are scoped to their owner", %{conn: conn} do
    node = Canvas.Store.create(%{"title" => "Preview owner"})
    path = Path.join(Canvas.Context.project_dir(node["id"]), "preview-fixture")
    File.write!(path, <<0x89, "PNG", 13, 10, 26, 10, 0, 0>>)

    Canvas.Store.attach(node["id"], %{
      "id" => "preview-image",
      "name" => "Image",
      "kind" => "image",
      "path" => path
    })

    response = get(conn, "/previews/#{node["id"]}/preview-image")
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png; charset=utf-8"]
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get(conn, "/previews/not-owner/preview-image").status == 404
    File.write!(path, "<svg>untrusted</svg>")
    assert get(conn, "/previews/#{node["id"]}/preview-image").status == 404
  end

  test "text previews stay bounded and binary sources require extraction" do
    node = Canvas.Store.create(%{"title" => "Text preview"})
    path = Path.join(Canvas.Context.project_dir(node["id"]), "text-fixture")
    File.write!(path, String.duplicate("context ", 1000))
    assert String.length(Canvas.Context.preview(%{"kind" => "file", "path" => path})) == 360
    File.write!(path, <<0, 255, 0>>)
    assert Canvas.Context.preview(%{"kind" => "file", "path" => path}) == nil
  end
end

defmodule CanvasWeb.AttachmentController do
  use CanvasWeb, :controller

  def preview(conn, %{"node_id" => node_id, "id" => id}) do
    node = Canvas.Store.get(node_id)
    attachment = if node, do: Enum.find(node["attachments"], &(&1["id"] == id))

    with %{"kind" => "image", "path" => path} <- attachment,
         {:ok, file} <- File.open(path, [:read, :binary]) do
      prefix = IO.binread(file, 16)
      File.close(file)

      mime =
        case prefix do
          <<0x89, "PNG", _::binary>> -> "image/png"
          <<0xFF, 0xD8, _::binary>> -> "image/jpeg"
          <<"GIF8", _::binary>> -> "image/gif"
          _ -> nil
        end

      if mime,
        do:
          conn
          |> put_resp_content_type(mime)
          |> put_resp_header("cache-control", "private, no-store")
          |> send_file(200, path),
        else: send_resp(conn, 404, "Preview unavailable")
    else
      _ -> send_resp(conn, 404, "Preview unavailable")
    end
  end

  def show(conn, %{"node_id" => node_id, "id" => id}) do
    node = Canvas.Store.get(node_id)
    attachment = if node, do: Enum.find(node["attachments"], &(&1["id"] == id))

    if attachment && attachment["path"] && File.regular?(attachment["path"]) do
      send_download(conn, {:file, attachment["path"]},
        filename: attachment["name"],
        content_type: "application/octet-stream"
      )
    else
      send_resp(conn, 404, "Attachment not found")
    end
  end
end

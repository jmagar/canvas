defmodule CanvasWeb.AttachmentController do
  use CanvasWeb, :controller

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

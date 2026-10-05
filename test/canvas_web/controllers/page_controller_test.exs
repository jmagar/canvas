defmodule CanvasWeb.PageControllerTest do
  use CanvasWeb.ConnCase

  test "GET / renders the canvas", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "spatial-canvas"
  end
end

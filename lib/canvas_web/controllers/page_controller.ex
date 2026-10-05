defmodule CanvasWeb.PageController do
  use CanvasWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

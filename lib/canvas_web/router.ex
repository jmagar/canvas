defmodule CanvasWeb.Router do
  use CanvasWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CanvasWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CanvasWeb do
    pipe_through :browser

    live "/", CanvasLive, :index
    get "/attachments/:node_id/:id", AttachmentController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", CanvasWeb do
  #   pipe_through :api
  # end
end

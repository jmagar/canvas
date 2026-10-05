defmodule Canvas.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CanvasWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:canvas, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Canvas.PubSub},
      Canvas.Store,
      {Registry, keys: :unique, name: Canvas.Codex.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Canvas.Codex.Supervisor},
      {Task.Supervisor, name: Canvas.Tasks},
      Canvas.Ingestion,
      # Start to serve requests, typically the last entry
      CanvasWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Canvas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CanvasWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

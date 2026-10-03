defmodule AiControl.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AiControlWeb.Telemetry,
      AiControlWeb.RequestLog,
      AiControl.Repo,
      AiControl.Accounts.LoginLimiter,
      AiControl.Policies.Cache,
      {DNSCluster, query: Application.get_env(:ai_control, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AiControl.PubSub},
      # Start a worker by calling: AiControl.Worker.start_link(arg)
      # {AiControl.Worker, arg},
      # Start to serve requests, typically the last entry
      AiControlWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AiControl.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AiControlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

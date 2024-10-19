defmodule Sequin.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  use Application

  alias Sequin.Databases.ConnectionCache
  alias Sequin.MutexedSupervisor

  @impl true
  def start(_type, _args) do
    env = Application.get_env(:sequin, :env)
    children = children(env)

    :ets.new(Sequin.Extensions.Replication.ets_table(), [:set, :public, :named_table])
    # Add this line to create the new ETS table for health debouncing
    :ets.new(Sequin.Health.debounce_ets_table(), [:set, :public, :named_table])

    :ets.new(Sequin.Consumers.posthog_ets_table(), [:set, :public, :named_table])

    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sequin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp children(:test) do
    base_children()
  end

  defp children(_) do
    base_children() ++
      [
        MutexedSupervisor.child_spec(Sequin.ReplicationRuntime.MutexedSupervisor, [Sequin.ReplicationRuntime.Supervisor]),
        Sequin.ReplicationRuntime.Supervisor,
        Sequin.ConsumersRuntime.Supervisor,
        Sequin.DatabasesRuntime.Supervisor,
        Sequin.Tracer.Starter,
        Sequin.Health.HttpEndpointHealthChecker,
        Sequin.Health.PostgresDatabaseHealthChecker
      ]
  end

  defp base_children do
    [
      Sequin.Registry,
      SequinWeb.Telemetry,
      Sequin.Repo,
      Sequin.Vault,
      {DNSCluster, query: Application.get_env(:sequin, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sequin.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Sequin.Finch},
      {Task.Supervisor, name: Sequin.TaskSupervisor},
      {ConCache, name: Sequin.Cache, ttl_check_interval: :timer.seconds(1), global_ttl: :infinity},
      {Oban, Application.fetch_env!(:sequin, Oban)},
      {Redix, Application.fetch_env!(:redix, :start_opts)},
      ConnectionCache,
      SequinWeb.Presence,
      Sequin.Tracer.DynamicSupervisor,
      # Start to serve requests, typically the last entry
      SequinWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SequinWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

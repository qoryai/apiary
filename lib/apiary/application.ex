defmodule Apiary.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # First, so a wrong QORY_FEATURES stops the boot before anything is started.
    Apiary.Features.boot!()
    # As early, so a wrong AUDIT_RETENTION_DAYS or TRUSTED_PROXIES stops the boot too.
    Apiary.Audit.boot!()
    ApiaryWeb.Origin.boot!()
    attach_request_log()
    # A job's failure, cancellation or discard is one line, with its organisation and
    # workspace ids and without its arguments.
    Apiary.Job.Log.attach()

    children =
      [
        ApiaryWeb.Telemetry,
        Apiary.Repo,
        Apiary.Vault,
        {DNSCluster, query: Application.get_env(:apiary, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Apiary.PubSub},
        {Task.Supervisor, name: Apiary.Runs.TaskSupervisor},
        Apiary.Runs.RateLimit
      ] ++
        migrator() ++
        [
          # The job queue, after the migrator so its tables exist when it
          # starts. `Apiary.Job` is what every job runs inside.
          {Oban, Application.fetch_env!(:apiary, Oban)}
        ] ++
        liveness() ++
        retention() ++
        [
          # Start to serve requests, typically the last entry
          ApiaryWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Apiary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ApiaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Migrations run before the endpoint starts, so a release never serves against a
  # schema it does not know. Production turns this on in config/runtime.exs.
  defp migrator do
    if Application.get_env(:apiary, :migrate_on_boot, false) do
      [Apiary.Release.Migrator]
    else
      []
    end
  end

  # The lost-run check, after the migrator so it never reads a schema it does not know.
  # Off in test, where the tests call `Apiary.Runs.Liveness.check/1` themselves.
  defp liveness do
    if Apiary.Runs.Liveness.enabled?(), do: [Apiary.Runs.Liveness], else: []
  end

  # The nightly retention job, after the migrator like the lost-run check. Off in test,
  # where the tests call `Apiary.Retention.prune_all/1` themselves.
  defp retention do
    if Apiary.Retention.Scheduler.enabled?(), do: [Apiary.Retention.Scheduler], else: []
  end

  # One JSON line per request, from the endpoint's `Plug.Telemetry` stop event. The
  # line carries method, path, status, duration, remote ip and user agent; never
  # request headers or bodies. The Phoenix request logger is off in production
  # (config/prod.exs) so each request is logged once. `ApiaryWeb.RequestLog` replaces
  # the bearer token in the paths that carry one before the line is written.
  defp attach_request_log do
    if Application.get_env(:apiary, :json_logs, false) do
      ApiaryWeb.RequestLog.attach()
    end
  end
end

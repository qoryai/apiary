defmodule Apiary.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # The jobs Oban's cron plugin enqueues, in UTC, each once a day: the audit trail's
  # retention sweep (`Apiary.Audit.PruneSweep`), the sweep of invitations expired for 30
  # days (`Apiary.Organisations.InvitationSweep`) and the purge of what was deleted and is
  # past its grace period (`Apiary.Deletion.PurgeSweep`). The edition's follow
  # (`Apiary.Edition.crontab/0`).
  @crontab [
    {"40 2 * * *", Apiary.Audit.PruneSweep},
    {"50 2 * * *", Apiary.Organisations.InvitationSweep},
    {"20 3 * * *", Apiary.Deletion.PurgeSweep}
  ]

  @impl true
  def start(_type, _args) do
    # First, so a wrong QORY_FEATURES, or an edition's features that do not add up, stops
    # the boot before anything is started.
    Apiary.Features.boot!()
    # As early, so a wrong AUDIT_RETENTION_DAYS, DELETION_GRACE_DAYS, INVITATIONS_PER_DAY,
    # TRUSTED_PROXIES, APIARY_SIGNING_SECRET or integration setting stops the boot too, and
    # so does an edition's table or subject the core has already, or a page whose feature
    # is none there is.
    Apiary.SigningKey.boot!()
    Apiary.Audit.boot!()
    Apiary.Deletion.boot!()
    Apiary.Deletion.Tables.boot!()
    Apiary.Instance.boot!()
    ApiaryWeb.Origin.boot!()
    Apiary.Integrations.Source.boot!()
    ApiaryWeb.Features.boot!()
    # The commit the release was built from, for GET /health.
    Apiary.Revision.boot!()
    # Then the edition's own settings, once the core's are known to be right.
    :ok = Apiary.Edition.boot!()
    # A database connection encrypted without its certificate checked is said once.
    Apiary.DatabaseUrl.boot()
    # Keeps an access key's secret out of log lines; Apiary.SecretLogFilter says what it
    # covers and what it does not.
    Apiary.SecretLogFilter.install()
    attach_request_log()
    # A job's failure, cancellation or discard is one line, with its organisation and
    # workspace ids and without its arguments.
    Apiary.Job.Log.attach()

    children = children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Apiary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  # The supervisor's children, in the order they start. The edition's processes come once
  # the core's are up and before requests come; the first admin's claim
  # (`Apiary.FirstAdmin`) after them, and just before the endpoint, so no web sign-up can
  # come before it.
  def children do
    [
      ApiaryWeb.Telemetry,
      Apiary.Repo,
      {DNSCluster, query: Application.get_env(:apiary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Apiary.PubSub},
      {Task.Supervisor, name: Apiary.Runs.TaskSupervisor},
      Apiary.Runs.RateLimit,
      Apiary.Nodes.Throttle
    ] ++
      migrator() ++
      key_check() ++
      mail_cache() ++
      [
        # The job queue, after the migrator so its tables exist when it
        # starts. `Apiary.Job` is what every job runs inside.
        {Oban, oban()}
      ] ++
      liveness() ++
      retention() ++
      Apiary.Edition.children() ++
      [
        Apiary.FirstAdmin,
        # Start to serve requests, typically the last entry
        ApiaryWeb.Endpoint
      ]
  end

  # Oban's configuration with the crontab built here, the core's and the edition's, so an
  # edition never restates Oban's configuration. Kept in the application's environment as
  # Oban runs with it.
  defp oban do
    config =
      Keyword.put(
        Application.fetch_env!(:apiary, Oban),
        :crontab,
        @crontab ++ Apiary.Edition.crontab()
      )

    Application.put_env(:apiary, Oban, config)
    config
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

  # The check that the instance runs with the keys it first started with, after the
  # migrator so the columns it reads exist, and before anything serves. It runs with
  # MIGRATE_ON_BOOT=false too. Off in test, where the tests call `Apiary.KeyCheck.check/0`.
  defp key_check do
    if Apiary.KeyCheck.enabled?(), do: [Apiary.KeyCheck], else: []
  end

  # The node's copy of the mail settings an instance admin saved, after the migrator so
  # their columns exist, and before anything that sends an email: it says once, then, when
  # no mail is set (`Apiary.Mail.boot/0`). Off in test, where `Apiary.Mail` reads them from
  # each test's sandbox.
  defp mail_cache do
    if Apiary.Mail.Cache.enabled?(), do: [Apiary.Mail.Cache], else: []
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

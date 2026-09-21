defmodule Apiary.Release do
  @moduledoc """
  Release tasks that run without Mix: migrations for `bin/migrate` and for
  `Apiary.Release.Migrator` at boot, and helpers that production configuration
  evaluates at runtime.
  """
  @app :apiary

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Projects runs again from their events, as `mix apiary.rebuild` does where there is Mix:
  `bin/apiary eval "Apiary.Release.rebuild()"`. `all: true` for every run, `batch:` for
  the batch size. See `Apiary.Runs.Rebuild`.
  """
  def rebuild(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          # A projection announces itself; outside the running application nobody listens,
          # but the name has to exist.
          {:ok, pubsub} =
            Supervisor.start_link([{Phoenix.PubSub, name: Apiary.PubSub}], strategy: :one_for_one)

          result = Apiary.Runs.Rebuild.run(opts)
          Supervisor.stop(pubsub)
          result
        end)

      result
    end
  end

  @doc """
  Renders every managed hive's run configurations again, as `mix apiary.policy.rerender`
  does where there is Mix: `bin/apiary eval "Apiary.Release.policy_rerender()"`. See
  `Apiary.Policy.rerender_all/0`.
  """
  def policy_rerender do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          # A new version is announced; outside the running application nobody listens,
          # but the name has to exist.
          {:ok, pubsub} =
            Supervisor.start_link([{Phoenix.PubSub, name: Apiary.PubSub}], strategy: :one_for_one)

          result = Apiary.Policy.rerender_all()
          Supervisor.stop(pubsub)
          result
        end)

      result
    end
  end

  @doc """
  Runs the retention job now, as `mix apiary.prune` does where there is Mix:
  `bin/apiary eval "Apiary.Release.prune()"`. `dry_run: true` deletes nothing and prints
  the same counts. See `Apiary.Retention`.
  """
  def prune(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Apiary.Retention.prune_all(Keyword.put_new(opts, :trigger, "manual"))
        end)

      case result do
        {:ok, []} -> IO.puts("No hive has a retention setting: nothing to prune.")
        {:ok, results} -> Enum.each(results, &IO.puts(Apiary.Retention.sentence(&1)))
        {:error, :locked} -> IO.puts("The retention job is already running on this database.")
      end

      result
    end
  end

  @doc """
  True when `PUBLIC_URL` is plain `http://`.

  `config/prod.exs` passes this to `Plug.SSL` as an `:exclude` condition, so an
  instance published over plain HTTP (a LAN, a trial on one machine) is not redirected
  to an HTTPS address that does not exist. With an `https://` public URL every request
  is redirected unless the reverse proxy sends `X-Forwarded-Proto: https`.
  """
  def plain_http?(_conn) do
    Application.get_env(@app, :public_url_scheme) == "http"
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end

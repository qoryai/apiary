defmodule Apiary.Runs.PushCredentialMigrationTest do
  # The migration of the push entry, run down and up again inside the test's transaction,
  # which rolls it all back: up lets a run have a `push` entry with access `write`, one per
  # run, and keeps the apply items of its first credential; down refuses while a `push` row
  # exists, then takes the purpose and its index away. Not async: it changes the schema
  # under other tests.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.Runs.{RunCredential, RunCredentials}
  alias Apiary.WorkItems.WorkItem

  @version 20_261_118_090_000
  @migration Apiary.Repo.Migrations.KeepAWriteRunSPushCredentialEntry

  @apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
  ]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_write_run_s_push_credential_entry.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # The constraint that refuses the write of `fun`, as the schema's insert or a statement
  # raises it.
  defp refused(constraint, fun) do
    named =
      try do
        fun.()
        nil
      rescue
        error in Ecto.ConstraintError -> error.constraint
        error in Postgrex.Error -> error.postgres.constraint
      end

    assert named == constraint
  end

  # A claimed run with its work entry, and the push entry its claim would add.
  setup do
    %{scope: scope} = sign_up_fixture()
    ctx = Apiary.SealedRunsFixtures.sealed_run_fixture(scope, work: @apply)
    work = Repo.get_by!(RunCredential, run_id: ctx.run.id, purpose: :work)
    item = %WorkItem{public_id: "wi_0123456789abcdef"}
    push = RunCredentials.push_from(work, :write, item)
    %{run: ctx.run, work: work, push: %{Ecto.put_meta(push, state: :built) | id: nil}}
  end

  defp entry_names(run),
    do:
      Repo.all(
        from c in RunCredential, where: c.run_id == ^run.id, select: c.name, order_by: c.name
      )

  test "up takes one push entry with access write per run, and its issued apply items", ctx do
    Repo.insert!(ctx.push)
    assert entry_names(ctx.run) == ["push-1", "work-1"]

    refused("run_credentials_push_index", fn -> Repo.insert!(%{ctx.push | name: "push-2"}) end)

    refused("run_credentials_entry_check", fn ->
      Repo.insert!(%{ctx.push | name: "push-2", access: :read})
    end)

    refused("run_credentials_entry_check", fn -> Repo.insert!(%{ctx.push | name: "work-2"}) end)

    items = [%{"hosts" => ["git.example.com"]}]

    {1, _rows} =
      Repo.update_all(from(c in RunCredential, where: c.purpose == :push),
        set: [issued_apply: items]
      )
  end

  test "down refuses while a push entry exists, then takes the purpose and its index away",
       ctx do
    Repo.insert!(ctx.push)

    error = assert_raise(Postgrex.Error, &down!/0)
    assert error.postgres.message =~ "Delete the run_credentials rows with purpose push"

    Repo.delete_all(from c in RunCredential, where: c.purpose == :push)
    down!()

    refused("run_credentials_entry_check", fn -> Repo.insert!(ctx.push) end)

    # The entries that exist before the migration stay valid, a work entry with write too.
    {1, _rows} =
      Repo.update_all(from(c in RunCredential, where: c.purpose == :work), set: [access: :write])

    {1, _rows} =
      Repo.update_all(from(c in RunCredential, where: c.purpose == :work),
        set: [issued_apply: [%{"hosts" => []}]]
      )

    up!()
    Repo.insert!(ctx.push)
    assert entry_names(ctx.run) == ["push-1", "work-1"]
  end
end

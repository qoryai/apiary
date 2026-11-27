defmodule Apiary.Runs.HarnessCredentialMigrationTest do
  # The migration of the harness entries, run down and up again inside the test's
  # transaction, which rolls it all back: up lets a `harness` row have a grant and no
  # connection, and keep the apply items of its first credential; down refuses while a
  # `harness` row exists, then makes every row's connection required again. Not async: it
  # changes the schema under other tests.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.Runs.RunCredential

  @version 20_261_127_150_200
  @migration Apiary.Repo.Migrations.KeepARunSHarnessCredentialEntries

  @apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
  ]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_run_s_harness_credential_entries.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A claimed run with its work entry, a live grant of the work entry's connection, and
  # the harness entry a claim would add under it.
  setup do
    %{scope: scope} = sign_up_fixture()
    ctx = Apiary.SealedRunsFixtures.sealed_run_fixture(scope, work: @apply)
    work = Repo.get_by!(RunCredential, run_id: ctx.run.id, purpose: :work)
    connection = Repo.get!(Apiary.Adapters.Connection, work.connection_id)

    grant =
      Repo.one(
        from g in Apiary.Adapters.Grant,
          where: g.connection_id == ^connection.id and is_nil(g.ended_at)
      ) ||
        Apiary.HarnessReadsFixtures.live_grant_fixture(
          connection.organisation_id,
          %{id: connection.adapter_id},
          connection,
          "G_harness"
        )

    harness = %{
      Ecto.put_meta(work, state: :built)
      | id: nil,
        name: "harness-1",
        purpose: :harness,
        access: :read,
        connection_id: nil,
        grant_id: grant.id,
        resources: [%{"resource_ref" => "R_harness", "sources" => []}],
        issued_apply: nil
    }

    %{run: ctx.run, harness: harness}
  end

  # The apply items of the first credential, written on the entry `name` of `run`, with
  # a statement that names no column of the schema: down removes `grant_id`.
  defp kept!(run, name) do
    Repo.query!(
      "UPDATE run_credentials SET issued_apply = '[{\"hosts\": []}]'::jsonb " <>
        "WHERE run_id = $1 AND name = $2",
      [Ecto.UUID.dump!(run.id), name]
    )
  end

  test "up takes a harness entry with a grant and no connection, and its issued apply items",
       ctx do
    Repo.insert!(ctx.harness)
    assert %{num_rows: 1} = kept!(ctx.run, "harness-1")
  end

  test "down refuses while a harness entry exists, then requires a connection on every row",
       ctx do
    Repo.insert!(ctx.harness)

    error = assert_raise(Postgrex.Error, &down!/0)
    assert error.postgres.message =~ "Delete the run_credentials rows with purpose harness"

    Repo.delete_all(from c in RunCredential, where: c.purpose == :harness)
    down!()

    # Before the migration a row has a connection and no grant column; a work entry keeps
    # its issued apply items.
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE run_credentials SET connection_id = NULL WHERE run_id = $1", [
          Ecto.UUID.dump!(ctx.run.id)
        ])
      end

    assert error.postgres.code == :not_null_violation
    assert %{num_rows: 1} = kept!(ctx.run, "work-1")

    up!()
    Repo.insert!(ctx.harness)

    assert ["harness-1", "work-1"] ==
             Repo.all(
               from c in RunCredential,
                 where: c.run_id == ^ctx.run.id,
                 select: c.name,
                 order_by: c.name
             )
  end
end

defmodule Apiary.PublicId.InsertDefaultTest do
  # A row written without a public id gets one from the column's default, a function such
  # as `target_public_id()` or `source_item_public_id()`. When the default returns an id a
  # row has, the insert runs again, and the default returns another. The function is
  # replaced in the test's transaction (the replacement is rolled back with it) by one
  # that returns the id of an existing row on its first call and a random one on the next,
  # so the test does not depend on the 80 random bits. The module is not async: replacing a
  # function takes a lock that other tests' inserts would wait on.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{PublicId, Repo, Sources}
  alias Apiary.PublicId.Insert
  alias Apiary.Runs.Target
  alias Apiary.Sources.Item

  # Makes `function` return `taken` on its first call, then a random id of `prefix`. A
  # sequence counts the calls, as a rolled back savepoint does not undo `nextval`.
  defp replace_default!(function, prefix, taken) do
    Repo.query!("CREATE SEQUENCE public.test_#{function}_calls")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.#{function}() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    BEGIN
      IF nextval('public.test_#{function}_calls') = 1 THEN RETURN '#{taken}'; END IF;
      RETURN '#{prefix}_' || substr(md5(random()::text), 1, 16);
    END
    $$
    """)
  end

  describe "a target" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: scope}
    end

    defp target(scope, path) do
      %Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "git.example",
        path: path,
        first_seen_at: DateTime.utc_now()
      }
    end

    test "inserted without an id runs again when the default returns one a row has", %{
      scope: scope
    } do
      taken = Repo.insert!(target(scope, "acme/taken")).public_id
      replace_default!("target_public_id", "tg", taken)

      assert {:ok, created} =
               Insert.insert(target(scope, "acme/new"), fn row ->
                 send(self(), :try)
                 Repo.insert(row)
               end)

      assert_received :try
      assert_received :try
      refute_received :try
      assert created.public_id != taken
      assert PublicId.valid?("tg", created.public_id)
    end

    test "inserted by insert_all/3 without ids runs again, and each row gets a default", %{
      scope: scope
    } do
      taken = Repo.insert!(target(scope, "acme/taken")).public_id
      replace_default!("target_public_id", "tg", taken)
      now = DateTime.utc_now()

      rows =
        for path <- ["acme/one", "acme/two"] do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id,
            system: "git.example",
            path: path,
            first_seen_at: now,
            inserted_at: now,
            updated_at: now
          }
        end

      assert {2, _} = Insert.insert_all(Target, rows)
      ids = Repo.all(from t in Target, select: t.public_id)
      assert length(Enum.uniq(ids)) == 3
    end
  end

  describe "a ticket" do
    @describetag needs: :factory

    setup do
      %{scope: scope} = sign_up_fixture()
      connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
      {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

      %{
        key_scope: key_scope(connectable.access_key),
        trk: source_collection_fixture(scope, connection, %{external_ref: "TRK"}),
        connection: connection
      }
    end

    defp post(ctx, items),
      do: Sources.post_items(ctx.key_scope, items_body("TRK", items, []))

    test "that an adapter posts, with a default id that is taken, is stored under another", ctx do
      assert {:ok, _answer} = post(ctx, [item("TRK-1")])
      taken = Repo.get_by!(Item, external_ref: "TRK-1").public_id
      replace_default!("source_item_public_id", "tk", taken)

      assert {:ok, _answer} = post(ctx, [item("TRK-2")])

      second = Repo.get_by!(Item, external_ref: "TRK-2")
      assert second.public_id != taken
      assert PublicId.valid?("tk", second.public_id)
      assert Repo.get_by!(Item, external_ref: "TRK-1").public_id == taken
    end
  end
end

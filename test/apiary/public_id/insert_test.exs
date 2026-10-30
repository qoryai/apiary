defmodule Apiary.PublicId.InsertTest do
  # An insert whose public id collides runs again with a fresh id, up to
  # `Apiary.PublicId.Insert.max_tries/0` tries, and for no other refusal. A collision is
  # made with `Apiary.PublicIdSource`, which queues the random part of the next id made
  # in the test's process, so the id equals one the test inserted.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{PublicId, PublicIdSource, Repo}
  alias Apiary.Organisations.{Slug, Workspace}
  alias Apiary.PublicId.Insert
  alias Apiary.Runs.Target

  @taken "0123456789abcdef"

  setup do
    %{scope: scope, organisation: organisation} = sign_up_fixture()
    %{scope: scope, organisation: organisation}
  end

  # The changeset of a new workspace. Its public id is made here, so a queued id is taken
  # by the call.
  defp workspace_changeset(organisation, name) do
    %Workspace{organisation_id: organisation.id}
    |> Workspace.create_changeset(%{name: name, domain: "software"})
    |> Workspace.put_slug(Slug.from_name(name))
  end

  # A workspace whose public id is `ws_` and `@taken`.
  defp taken_workspace!(organisation) do
    PublicIdSource.force([@taken])
    organisation |> workspace_changeset("Taken") |> Repo.insert!()
  end

  defp counting(subject) do
    send(self(), :try)
    Repo.insert(subject)
  end

  defp tries(count \\ 0) do
    receive do
      :try -> tries(count + 1)
    after
      0 -> count
    end
  end

  describe "PublicIdSource" do
    test "the queued ids are the next ones made, with the prefix asked for, then random again" do
      PublicIdSource.force([@taken, "ffffffffffffffff"])

      assert PublicId.generate("ws") == "ws_0123456789abcdef"
      assert PublicId.generate("nd") == "nd_ffffffffffffffff"

      third = PublicId.generate("ws")
      assert PublicId.valid?("ws", third)
      assert third != "ws_" <> @taken
    end

    test "an entry that is not 16 characters of the alphabet is refused" do
      assert_raise ArgumentError, fn -> PublicIdSource.force(["short"]) end
      assert_raise ArgumentError, fn -> PublicIdSource.force(["0123456789abcdei"]) end
    end
  end

  describe "insert/2" do
    test "a changeset whose id is taken is inserted with a fresh id of the same prefix",
         %{organisation: organisation} do
      taken = taken_workspace!(organisation)
      assert taken.public_id == "ws_" <> @taken

      PublicIdSource.force([@taken])
      changeset = workspace_changeset(organisation, "Second")

      assert {:ok, second} = Insert.insert(changeset, &counting/1)
      assert tries() == 2
      assert second.public_id != taken.public_id
      assert PublicId.valid?("ws", second.public_id)
      assert Repo.get!(Workspace, second.id).public_id == second.public_id
    end

    test "a collision on every try returns the changeset error of the id, after 3 tries",
         %{organisation: organisation} do
      taken_workspace!(organisation)

      # The first id is made with the changeset, the second and the third by `insert/2`:
      # all three come from the queue.
      PublicIdSource.force([@taken, @taken, @taken])
      changeset = workspace_changeset(organisation, "Second")

      assert {:error, refused} = Insert.insert(changeset, &counting/1)
      assert tries() == 3
      assert {_message, meta} = refused.errors[:public_id]
      assert meta[:constraint] == :unique
      assert meta[:constraint_name] == "workspaces_public_id_index"
    end

    test "a struct with no id is inserted as it is, and its error is the first one's",
         %{scope: scope} do
      row = %Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "git.example",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      }

      assert {:ok, target} = Insert.insert(row)
      assert target.public_id =~ ~r/\Atg_/

      # The same system and path: another constraint, so one try.
      assert_raise Ecto.ConstraintError, ~r/targets_workspace_id_system_path_index/, fn ->
        Insert.insert(row, &counting/1)
      end

      assert tries() == 1
    end

    test "another constraint is returned at the first try", %{organisation: organisation} do
      {:ok, _first} = organisation |> workspace_changeset("Same name") |> Repo.insert()

      changeset = workspace_changeset(organisation, "Same name")
      assert {:error, refused} = Insert.insert(changeset, &counting/1)
      assert tries() == 1
      assert Keyword.has_key?(refused.errors, :name)
      refute Keyword.has_key?(refused.errors, :public_id)
    end

    test "a refused try inside a transaction rolls back to its savepoint, so the transaction goes on",
         %{organisation: organisation} do
      taken = taken_workspace!(organisation)

      assert {:ok, {before, second}} =
               Repo.transaction(fn ->
                 before = organisation |> workspace_changeset("Before") |> Repo.insert!()

                 PublicIdSource.force([@taken])
                 changeset = workspace_changeset(organisation, "Second")
                 {:ok, second} = Insert.insert(changeset, &counting/1)

                 # The transaction is not aborted: a later statement runs.
                 assert Repo.get!(Workspace, before.id).name == "Before"
                 {before, second}
               end)

      assert tries() == 2
      assert second.public_id != taken.public_id
      assert Repo.get!(Workspace, before.id)
      assert Repo.get!(Workspace, second.id)
    end
  end

  describe "insert!/2" do
    test "returns the struct, retrying a collision", %{organisation: organisation} do
      taken_workspace!(organisation)
      PublicIdSource.force([@taken])
      changeset = workspace_changeset(organisation, "Second")

      assert %Workspace{} = second = Insert.insert!(changeset)
      assert second.public_id != "ws_" <> @taken
    end

    test "raises for a changeset that is refused", %{organisation: organisation} do
      changeset = workspace_changeset(organisation, "")
      assert_raise Ecto.InvalidChangesetError, fn -> Insert.insert!(changeset) end
    end
  end

  describe "insert_all/3" do
    defp target_row(scope, path, public_id) do
      now = DateTime.utc_now()

      %{
        id: Ecto.UUID.generate(),
        public_id: public_id,
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "git.example",
        path: path,
        first_seen_at: now,
        inserted_at: now,
        updated_at: now
      }
    end

    test "a row whose id is taken makes every row of the insert take a fresh id", %{scope: scope} do
      {1, _} = Repo.insert_all(Target, [target_row(scope, "acme/taken", "tg_" <> @taken)])

      rows = [
        target_row(scope, "acme/one", "tg_" <> @taken),
        target_row(scope, "acme/two", "tg_ffffffffffffffff")
      ]

      assert {2, _} = Insert.insert_all(Target, rows)

      ids = Repo.all(from t in Target, select: t.public_id)
      assert length(Enum.uniq(ids)) == 3
      assert Enum.all?(ids, &PublicId.valid?("tg", &1))
    end

    test "another constraint raises at the first try", %{scope: scope} do
      {1, _} = Repo.insert_all(Target, [target_row(scope, "acme/shop", "tg_" <> @taken)])

      assert_raise Postgrex.Error, ~r/targets_workspace_id_system_path_index/, fn ->
        Insert.run("targets", fn number ->
          send(self(), {:try, number})
          Repo.insert_all(Target, [target_row(scope, "acme/shop", "tg_ffffffffffffffff")])
        end)
      end

      assert_received {:try, 1}
      refute_received {:try, 2}
    end

    test "a collision on every try raises the database's error after 3 tries", %{scope: scope} do
      {1, _} = Repo.insert_all(Target, [target_row(scope, "acme/taken", "tg_" <> @taken)])
      assert Insert.max_tries() == 3

      assert_raise Postgrex.Error, ~r/targets_public_id_index/, fn ->
        Insert.run("targets", fn number ->
          send(self(), {:try, number})
          Repo.insert_all(Target, [target_row(scope, "acme/one", "tg_" <> @taken)])
        end)
      end

      assert_received {:try, 1}
      assert_received {:try, 2}
      assert_received {:try, 3}
      refute_received {:try, 4}
    end
  end

  describe "run/2" do
    test "{:error, :public_id_taken} is tried again, up to 3 tries, and is the last result" do
      assert {:error, :public_id_taken} =
               Insert.run(Target, fn number ->
                 send(self(), {:try, number})
                 {:error, :public_id_taken}
               end)

      assert_received {:try, 3}
      refute_received {:try, 4}

      assert :ok =
               Insert.run(Target, fn
                 1 -> {:error, :public_id_taken}
                 _ -> :ok
               end)
    end

    test "another error is the result of the first try" do
      assert {:error, :nope} =
               Insert.run(Target, fn number ->
                 send(self(), {:try, number})
                 {:error, :nope}
               end)

      assert_received {:try, 1}
      refute_received {:try, 2}

      assert_raise RuntimeError, "boom", fn -> Insert.run(Target, fn _ -> raise "boom" end) end
    end
  end

  describe "the unique indexes of public ids" do
    test "each table that makes a public id has the unique index `Insert` looks for" do
      schemas = [
        Apiary.Connections.Connection,
        Apiary.Connections.ServiceDefinition,
        Apiary.Secrets.Secret,
        Apiary.Nodes.Node,
        Apiary.Dispatches.Dispatch,
        Apiary.Adapters.Connection,
        Apiary.Adapters.Collection,
        Apiary.Organisations.Workspace,
        Apiary.WorkItems.WorkItem,
        Apiary.WorkItems.Comment,
        Apiary.Sources.Item,
        Apiary.Runs.Run,
        Apiary.Runs.Target
      ]

      for schema <- schemas do
        table = schema.__schema__(:source)

        %{rows: [[definition]]} =
          Repo.query!(
            "SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexname = $2",
            [table, table <> "_public_id_index"]
          )

        assert definition =~ "CREATE UNIQUE INDEX"
        assert definition =~ "(public_id)"
      end
    end
  end
end

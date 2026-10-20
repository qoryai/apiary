defmodule Apiary.PublicId.CallersTest do
  # What a caller that inserts a row with a public id does when the id is taken: it
  # stores the row under a fresh id (`Apiary.PublicId.Insert`). A collision is made with
  # `Apiary.PublicIdSource`, which queues the random part of the next ids made in the
  # test's process.
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, PublicId, PublicIdSource, Repo, Secrets}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Batch, Ingest, Registration, Run, Target}
  alias Apiary.Secrets.Secret

  @taken "0123456789abcdef"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  describe "a secret" do
    @describetag needs: :secrets

    test "whose id is taken is stored under a fresh id", %{scope: scope} do
      PublicIdSource.force([@taken])
      {:ok, first} = Secrets.create_secret(scope, %{name: "FIRST", value: "one"})
      assert first.public_id == "sec_" <> @taken

      PublicIdSource.force([@taken])
      assert {:ok, second} = Secrets.create_secret(scope, %{name: "SECOND", value: "two"})
      assert second.public_id != first.public_id
      assert PublicId.valid?("sec", second.public_id)
      assert Repo.get!(Secret, second.id).name == "SECOND"
    end

    test "is refused by the changeset's error when every try collides", %{scope: scope} do
      PublicIdSource.force([@taken])
      {:ok, _first} = Secrets.create_secret(scope, %{name: "FIRST", value: "one"})

      PublicIdSource.force([@taken, @taken, @taken])

      assert_raise Ecto.ConstraintError, ~r/secrets_public_id_index/, fn ->
        Secrets.create_secret(scope, %{name: "SECOND", value: "two"})
      end

      assert Repo.aggregate(from(s in Secret, where: s.name == "SECOND"), :count) == 0
    end
  end

  describe "a node" do
    test "whose id is taken is created under a fresh id, inside create_node/2's transaction",
         %{scope: scope} do
      PublicIdSource.force([@taken])
      first = node_fixture(scope)
      assert first.public_id == "nd_" <> @taken

      PublicIdSource.force([@taken])
      second = node_fixture(scope)
      assert second.public_id != first.public_id
      assert PublicId.valid?("nd", second.public_id)
      assert Repo.get!(Node, second.id)
    end

    test "raises the database's error when every try collides, and stores nothing",
         %{scope: scope} do
      PublicIdSource.force([@taken])
      node_fixture(scope)
      before = Repo.aggregate(Node, :count)

      PublicIdSource.force([@taken, @taken, @taken])

      assert_raise Ecto.ConstraintError, ~r/nodes_public_id_index/, fn ->
        node_fixture(scope)
      end

      assert Repo.aggregate(Node, :count) == before
    end
  end

  describe "a workspace" do
    test "made with an organisation, whose id is taken, is stored under a fresh id" do
      PublicIdSource.force([@taken])
      first = sign_up_fixture().workspace
      assert first.public_id == "ws_" <> @taken

      PublicIdSource.force([@taken])
      second = sign_up_fixture().workspace
      assert second.public_id != first.public_id
      assert PublicId.valid?("ws", second.public_id)
      assert Repo.get!(Workspace, second.id)
    end

    test "created in an organisation, whose id is taken, is stored under a fresh id",
         %{scope: scope} do
      # The core's edition allows one workspace in use: the first is marked for deletion,
      # and its row, which keeps its id, is the one the new id collides with.
      now = DateTime.utc_now()

      scope.workspace
      |> Ecto.Changeset.change(
        public_id: "ws_" <> @taken,
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      )
      |> Repo.update!()

      scope = Organisations.load_scope(Scope.for_user(scope.user), scope.organisation.id)
      PublicIdSource.force([@taken])

      assert {:ok, created} =
               Organisations.create_workspace(scope, %{"name" => "Second", "domain" => "software"})

      assert created.public_id != "ws_" <> @taken
      assert PublicId.valid?("ws", created.public_id)
    end
  end

  describe "a run" do
    setup %{scope: scope} do
      %{access_key: key} = access_key_fixture(scope)
      %{key: key}
    end

    defp batch!(events) do
      {:ok, batch} = events |> Jason.encode!() |> Batch.parse()
      batch
    end

    defp ingest(key) do
      {_subject, [started]} = first_events()
      Ingest.ingest(key, batch!([started]), %{contract_version: 1})
    end

    test "that its first batch creates, with an id that is taken, gets a fresh id", %{key: key} do
      PublicIdSource.force([@taken])
      assert {:ok, %{run: first}} = ingest(key)
      assert first.public_id == "rn_" <> @taken

      PublicIdSource.force([@taken])
      assert {:ok, %{run: second}} = ingest(key)
      assert second.public_id != first.public_id
      assert PublicId.valid?("rn", second.public_id)
    end

    defp registration_body(run_id) do
      %{
        "version" => 1,
        "run_id" => run_id,
        "labels" => %{"forge" => "git.example.com", "repository" => "acme/shop"},
        "about" => %{"kind" => "fix", "subjects" => [%{"type" => "issue", "ref" => "77"}]},
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      }
    end

    defp register(key, run_id) do
      bytes = run_id |> registration_body() |> Jason.encode!()
      {:ok, registration} = Registration.parse(Jason.decode!(bytes))

      Registration.register(key, registration, %{
        body: bytes,
        contract_version: 1,
        instance_id: "i_one"
      })
    end

    test "that a registration creates, with an id that is taken, gets a fresh id", %{key: key} do
      PublicIdSource.force([@taken])
      assert {:ok, %{run: first, repeated: false}} = register(key, Ecto.UUID.generate())
      assert first.public_id == "rn_" <> @taken

      PublicIdSource.force([@taken])
      assert {:ok, %{run: second, repeated: false}} = register(key, Ecto.UUID.generate())
      assert second.public_id != first.public_id
      assert Repo.get!(Run, second.id).public_id == second.public_id
    end

    test "that a registration creates is unavailable, and nothing is stored, when every try collides",
         %{key: key} do
      PublicIdSource.force([@taken])
      assert {:ok, %{run: first}} = register(key, Ecto.UUID.generate())

      PublicIdSource.force([@taken, @taken, @taken])

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unavailable} = register(key, Ecto.UUID.generate())
      end)

      assert [^first] = Repo.all(Run)
    end

    test "that a registration repeats keeps the run and its id, with no retry", %{key: key} do
      run_id = Ecto.UUID.generate()
      assert {:ok, %{run: first}} = register(key, run_id)

      assert {:ok, %{run: again, repeated: true}} = register(key, run_id)
      assert again.public_id == first.public_id
    end
  end

  describe "a target" do
    test "that a run names, with an id that is taken, gets a fresh id", %{scope: scope} do
      PublicIdSource.force([@taken])

      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: "git", path: "a/one"}
      ])

      PublicIdSource.force([@taken])

      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: "git", path: "a/two"}
      ])

      ids = Repo.all(from t in Target, order_by: t.path, select: {t.path, t.public_id})
      assert [{"a/one", "tg_" <> @taken}, {"a/two", second}] = ids
      assert PublicId.valid?("tg", second)
      assert second != "tg_" <> @taken
    end
  end

  describe "an adapter's connection" do
    @describetag needs: :factory

    setup %{scope: scope} do
      first = connectable_adapter_fixture(%{name: unique_adapter_name("First tracker")})
      second = connectable_adapter_fixture(%{name: unique_adapter_name("Second tracker")})
      %{scope: scope, first: first.adapter, second: second.adapter}
    end

    test "that a press of Connect starts, with an id that is taken, gets a fresh id", ctx do
      PublicIdSource.force([@taken])
      {first, _nonce} = connection_fixture(ctx.scope, ctx.first, :pending)
      assert first.public_id == "ac_" <> @taken

      PublicIdSource.force([@taken])
      {second, _nonce} = connection_fixture(ctx.scope, ctx.second, :pending)
      assert second.public_id != first.public_id
      assert PublicId.valid?("ac", second.public_id)
    end

    test "that replaces a connected one, with an id that is taken, gets a fresh id and a pass for it",
         ctx do
      PublicIdSource.force([@taken])
      {first, _nonce} = connection_fixture(ctx.scope, ctx.first, :pending)
      assert first.public_id == "ac_" <> @taken

      {connected, _nonce} = connection_fixture(ctx.scope, ctx.second, :connected)

      PublicIdSource.force([@taken])
      assert {:ok, url, {public_id, _nonce}} = Apiary.Adapters.connect(ctx.scope, ctx.second)

      assert public_id != first.public_id
      assert public_id != connected.public_id
      assert url =~ "state="
      assert Repo.get_by!(Connection, public_id: public_id).state == :pending
      assert Repo.get!(Connection, connected.id).state == :ended
    end
  end
end

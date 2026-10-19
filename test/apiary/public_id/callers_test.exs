defmodule Apiary.PublicId.CallersTest do
  # What a caller that inserts a row with a public id does when the id is taken: it
  # stores the row under a fresh id (`Apiary.PublicId.Insert`). A collision is made with
  # `Apiary.PublicIdSource`, which queues the random part of the next ids made in the
  # test's process.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, PublicId, PublicIdSource, Repo, Secrets}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Secrets.Secret

  @taken "0123456789abcdef"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  describe "a secret" do
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
end

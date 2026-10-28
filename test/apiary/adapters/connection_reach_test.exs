defmodule Apiary.Adapters.ConnectionReachTest do
  # The workspaces an adapter's connection reaches: set as a press of Connect makes the
  # connection (`Apiary.Adapters.connect/3`), with the setting "Available to every
  # workspace in <organisation>" where the edition shows it, and never changed after;
  # `collection.assign` and the Backlog switch refusing a workspace it does not reach;
  # and a workspace's purge taking the workspace from it.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Deletion, Edition, EditionStubs}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, ConnectPass, Connection, Connections}
  alias Apiary.Adapters.ConnectionWorkspace
  alias Apiary.Organisations.Workspace

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, other: workspace_fixture(scope.organisation, "Second")}
  end

  defp reached(connection), do: Connections.reached(Repo.reload!(connection))

  defp connect!(scope, opts) do
    %{adapter: adapter} = connectable_adapter_fixture()
    {:ok, _url, {public_id, _nonce}} = Adapters.connect(scope, adapter, opts)
    Repo.get_by!(Connection, public_id: public_id)
  end

  # `connection` made to reach `workspace` alone, as an add in that workspace makes it.
  defp reach_only!(%Connection{} = connection, %Workspace{} = workspace) do
    Repo.delete_all(from w in ConnectionWorkspace, where: w.connection_id == ^connection.id)
    connection |> Ecto.Changeset.change(applies_to: "selected") |> Repo.update!()

    Repo.insert!(%ConnectionWorkspace{
      organisation_id: workspace.organisation_id,
      connection_id: connection.id,
      workspace_id: workspace.id
    })

    Repo.reload!(connection)
  end

  describe "the add" do
    test "in the core reaches the workspace it is made in, whatever the form sends", ctx do
      for opts <- [[], [everywhere: true], [everywhere: true, workspace: ctx.other]] do
        connection = connect!(ctx.scope, opts)
        workspace = Keyword.get(opts, :workspace, ctx.scope.workspace)
        assert connection.applies_to == "selected"
        assert reached(connection) == MapSet.new([workspace.id])
      end
    end

    test "with the setting shown: on reaches every workspace, off the one it is made in",
         ctx do
      :ok = Edition.put_test_stub(EditionStubs.ScopeSetting)

      every = connect!(ctx.scope, everywhere: true)
      assert every.applies_to == "all"
      assert reached(every) == :all
      refute Repo.exists?(from w in ConnectionWorkspace, where: w.connection_id == ^every.id)

      one = connect!(ctx.scope, everywhere: false, workspace: ctx.other)
      assert one.applies_to == "selected"
      assert reached(one) == MapSet.new([ctx.other.id])
    end

    test "a workspace of another organisation, or marked for deletion, is not found", ctx do
      %{adapter: adapter} = connectable_adapter_fixture()
      theirs = sign_up_fixture().scope.workspace

      assert Adapters.connect(ctx.scope, adapter, workspace: theirs) == {:error, :not_found}

      {:ok, _} = Deletion.delete_workspace(ctx.scope, ctx.other.id, ctx.other.slug)

      assert Adapters.connect(ctx.scope, adapter, workspace: ctx.other) ==
               {:error, :not_found}

      refute Repo.exists?(from k in Connection, where: k.adapter_id == ^adapter.id)
    end

    test "another press takes the connection, which keeps the reach its add set", ctx do
      %{adapter: adapter} = connectable_adapter_fixture()
      main = ctx.scope.workspace.id
      now = DateTime.utc_now()

      start = fn reach, at ->
        {:ok, result} =
          Repo.transaction(fn ->
            Connections.start(ctx.scope, adapter, ConnectPass.new_nonce(), reach: reach, now: at)
          end)

        result
      end

      {:ok, first, _pass, nil} =
        start.(%{"applies_to" => "selected", "workspace_ids" => [main]}, now)

      {:ok, again, _pass, nil} =
        start.(%{"applies_to" => "all", "workspace_ids" => []}, DateTime.add(now, 1, :second))

      assert again.id == first.id
      assert reached(again) == MapSet.new([main])
    end
  end

  describe "collection.assign" do
    test "refuses a workspace the collection's connection does not reach", ctx do
      collection = collection_fixture(ctx.scope, workspace_id: nil)

      connection =
        Repo.get!(Connection, collection.connection_id) |> reach_only!(ctx.scope.workspace)

      assert Collections.assign_collections(ctx.scope, connection, [collection.id], ctx.other) ==
               {:error, :not_reached}

      assert Repo.reload!(collection).workspace_id == nil

      assert {:ok, 1} =
               Collections.assign_collections(
                 ctx.scope,
                 connection,
                 [collection.id],
                 ctx.scope.workspace
               )

      # To no workspace is always allowed.
      assert {:ok, 1} =
               Collections.assign_collections(ctx.scope, connection, [collection.id], nil)
    end

    test "the Backlog switch refuses a collection in a workspace its connection does not reach",
         ctx do
      collection = collection_fixture(ctx.scope, workspace_id: ctx.other.id)

      connection =
        Repo.get!(Connection, collection.connection_id) |> reach_only!(ctx.scope.workspace)

      %Collection{backlog: backlog} = collection

      assert Collections.set_collection_backlog(ctx.scope, connection, collection.id, not backlog) ==
               {:error, :not_reached}

      assert Repo.reload!(collection).backlog == backlog
    end
  end

  test "a workspace's purge takes it from the workspaces a connection reaches", ctx do
    :ok = Edition.put_test_stub(EditionStubs.ScopeSetting)
    connection = connect!(ctx.scope, workspace: ctx.other)
    assert reached(connection) == MapSet.new([ctx.other.id])

    {:ok, _} = Deletion.delete_workspace(ctx.scope, ctx.other.id, ctx.other.slug)

    Repo.update_all(from(w in Workspace, where: w.id == ^ctx.other.id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert {:ok, :purged} =
             Deletion.purge_workspace(
               Scope.for_instance(ctx.scope.organisation, Repo.get!(Workspace, ctx.other.id))
             )

    assert %Connection{applies_to: "selected"} = Repo.reload!(connection)
    assert reached(connection) == MapSet.new()
  end
end

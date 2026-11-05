defmodule Apiary.GatewayServingTest do
  # Whom a gateway may serve, as the callers ask it: a claim (`Apiary.Dispatches.Handover`),
  # a run's batch, attach and reload (`Apiary.Runs.Sender`) and a node's choice
  # (`Apiary.Gateways`). The answer reads the gateway's row and the workspace's place: a
  # workspace marked for deletion is refused elsewhere, with a refusal of its own
  # (`Apiary.AccessKeys.place_in_use?/2`). Not async: the instance has one gateway in use.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{Access, Deletion, Gateways, Nodes}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.Handover
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Run, Sender, WorkCredential}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    second = workspace_fixture(scope.organisation)
    %{scope: scope, other: other, second: second}
  end

  # The workspace `workspace`, as a scope carries it once it is marked for deletion.
  defp marked(scope, workspace) do
    {:ok, _marked} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    Repo.get!(Apiary.Organisations.Workspace, workspace.id)
  end

  # A run through a gateway, as its row reads once it has its run key.
  defp through(scope), do: %{run_fixture(scope) | run_key_payload: "run-key"}

  describe "a gateway" do
    test "of a workspace serves that workspace alone", ctx do
      gateway = gateway_fixture(ctx.scope)

      assert Handover.serves?(gateway, ctx.scope.workspace)
      refute Handover.serves?(gateway, ctx.second)
      refute Handover.serves?(gateway, ctx.other.workspace)
    end

    test "of an organisation serves every workspace of it, and of no other", ctx do
      gateway = organisation_gateway_fixture(ctx.scope)

      assert Handover.serves?(gateway, ctx.scope.workspace)
      assert Handover.serves?(gateway, ctx.second)
      refute Handover.serves?(gateway, ctx.other.workspace)
    end

    test "of the instance serves every workspace", ctx do
      gateway = instance_gateway_fixture()

      assert Handover.serves?(gateway, ctx.scope.workspace)
      assert Handover.serves?(gateway, ctx.other.workspace)
    end

    test "serves a workspace marked for deletion", ctx do
      workspace = gateway_fixture(ctx.scope)
      organisation = organisation_gateway_fixture(ctx.scope)
      instance = instance_gateway_fixture()
      marked = marked(ctx.scope, ctx.second)
      assert %DateTime{} = marked.deletion_marked_at

      assert Handover.serves?(organisation, marked)
      assert Handover.serves?(instance, marked)
      refute Handover.serves?(workspace, marked)
    end

    test "that is deleted serves nothing, nor does a node that is no gateway", ctx do
      gateway = gateway_fixture(ctx.scope)
      {:ok, deleted} = Nodes.delete_node(ctx.scope, gateway)

      refute Handover.serves?(deleted, ctx.scope.workspace)

      refute Handover.serves?(
               node_fixture(ctx.scope, gateway_choice: "direct"),
               ctx.scope.workspace
             )

      refute Handover.serves?(pool_fixture(ctx.scope), ctx.scope.workspace)
    end
  end

  describe "a claim with no workspace yet" do
    test "is served by the instance's gateway in use alone", ctx do
      gateway = instance_gateway_fixture()

      assert Handover.serves?(gateway, nil)
      refute Handover.serves?(%{gateway | deleted_at: DateTime.utc_now()}, nil)
      refute Handover.serves?(gateway_fixture(ctx.scope), nil)
      refute Handover.serves?(organisation_gateway_fixture(ctx.scope), nil)
    end
  end

  describe "a run" do
    test "that goes direct is served whatever the key", ctx do
      run = run_fixture(ctx.scope)
      %{access_key: key} = access_key_fixture(ctx.other)

      assert Sender.serves?(run, Repo.preload(key, :node))
    end

    test "through a gateway is served by a key of a gateway that may serve its workspace", ctx do
      run = through(ctx.scope)

      %{access_key: serving} = access_key_fixture(ctx.scope, node: gateway_fixture(ctx.scope))
      %{access_key: elsewhere} = access_key_fixture(ctx.other, node: gateway_fixture(ctx.other))

      assert Sender.serves?(run, Repo.preload(serving, :node))
      refute Sender.serves?(run, Repo.preload(elsewhere, :node))
    end

    test "through a gateway is served by no key of a node or a node pool", ctx do
      run = through(ctx.scope)

      %{access_key: node_key} = access_key_fixture(ctx.scope)
      %{access_key: pool_key} = access_key_fixture(ctx.scope, node: pool_fixture(ctx.scope))

      refute Sender.serves?(run, Repo.preload(node_key, :node))
      refute Sender.serves?(run, Repo.preload(pool_key, :node))
    end

    test "is served by the key of a deleted gateway no more, as its row says", ctx do
      run = through(ctx.scope)
      gateway = gateway_fixture(ctx.scope)
      key = %AccessKey{node: %Node{gateway | deleted_at: DateTime.utc_now()}}

      assert Run.through_gateway?(run)
      refute Sender.serves?(run, key)
    end
  end

  describe "a node's choice" do
    test "of a gateway stands while its workspace is marked for deletion", ctx do
      gateway = organisation_gateway_fixture(ctx.scope)

      node = %Node{
        kind: :node,
        gateway_choice: :named,
        gateway_id: gateway.id,
        workspace_id: ctx.second.id,
        workspace: marked(ctx.scope, ctx.second)
      }

      assert Gateways.chosen(node).id == gateway.id
      assert Gateways.resolve(node) == {:error, :gateway_without_key}
    end

    test "of a gateway that may not serve its workspace leads nowhere", ctx do
      gateway = gateway_fixture(ctx.scope)

      node = %Node{
        kind: :node,
        gateway_choice: :named,
        gateway_id: gateway.id,
        workspace_id: ctx.second.id,
        workspace: ctx.second
      }

      assert Gateways.chosen(node) == nil
      assert Gateways.resolve(node) == {:error, :gateway_not_serving}
    end

    test "of a node that is no gateway leads nowhere", ctx do
      other_node = node_fixture(ctx.scope, gateway_choice: "direct")

      node = %Node{
        kind: :node,
        gateway_choice: :named,
        gateway_id: other_node.id,
        workspace_id: ctx.scope.workspace.id,
        workspace: ctx.scope.workspace
      }

      assert Gateways.chosen(node) == nil
      assert Gateways.resolve(node) == {:error, :gateway_not_serving}
    end
  end

  # The rule itself, in `Apiary.Access`: the key's scope, as the server contract makes it.
  describe "a gateway's key, asked in `Apiary.Access` of a run" do
    # The actions a gateway's key holds whose feature is on in this leg: `security`, of
    # `run_configuration.fetch`, is off under `observability` alone.
    defp key_actions do
      Enum.filter(
        [:"run.post_events", :"run_configuration.fetch"],
        &Apiary.Features.on?(Access.feature(&1))
      )
    end

    defp key_scope(scope, gateway) do
      %{access_key: key} = access_key_fixture(scope, node: gateway)
      scope_of(key)
    end

    defp scope_of(key) do
      AccessKey
      |> Repo.get!(key.id)
      |> Repo.preload([:workspace, :node])
      |> Scope.for_access_key()
    end

    @tag :feature_sets
    test "of a workspace acts for that workspace alone", ctx do
      key_scope = key_scope(ctx.scope, gateway_fixture(ctx.scope))
      second = workspace_scope(ctx.scope.user, ctx.second)

      for action <- key_actions() do
        assert Access.check(key_scope, action, run_fixture(ctx.scope)) == :ok
        assert Access.check(key_scope, action, run_fixture(second)) == {:error, :not_found}
        assert Access.check(key_scope, action, run_fixture(ctx.other)) == {:error, :not_found}
      end
    end

    @tag :feature_sets
    test "of an organisation acts for every workspace of it, and of no other", ctx do
      key_scope = key_scope(ctx.scope, organisation_gateway_fixture(ctx.scope))
      second = workspace_scope(ctx.scope.user, ctx.second)

      for action <- key_actions() do
        assert Access.check(key_scope, action, run_fixture(ctx.scope)) == :ok
        assert Access.check(key_scope, action, run_fixture(second)) == :ok
        assert Access.check(key_scope, action, run_fixture(ctx.other)) == {:error, :not_found}
      end
    end

    @tag :feature_sets
    test "of the instance acts for any workspace", ctx do
      %{access_key: key} = installed_key_fixture(instance_gateway_fixture())
      key_scope = Scope.for_access_key(key)

      for action <- key_actions() do
        assert Access.check(key_scope, action, run_fixture(ctx.scope)) == :ok
        assert Access.check(key_scope, action, run_fixture(ctx.other)) == :ok
      end
    end

    test "gains nothing beyond what it held, asked of anything else", ctx do
      key_scope = key_scope(ctx.scope, organisation_gateway_fixture(ctx.scope))
      run = run_fixture(ctx.scope)

      # Of the organisation, where the key is; of a workspace of it, as before.
      assert Access.check(key_scope, :"run.post_events", ctx.scope.organisation) == :ok

      assert Access.check(key_scope, :"run.post_events", ctx.scope.workspace) ==
               {:error, :not_found}

      # Of any action its role does not hold.
      assert Access.check(key_scope, :"run.read", run) == {:error, :not_found}
      assert Access.check(key_scope, :"run.read_log", run) == {:error, :not_found}
    end

    test "keeps the refusal of a workspace marked for deletion", ctx do
      gateway = gateway_fixture(ctx.scope)
      %{access_key: key} = access_key_fixture(ctx.scope, node: gateway)
      marked = marked(ctx.scope, ctx.scope.workspace)
      key_scope = Scope.for_access_key(%{key | workspace: marked, node: gateway})

      assert Access.check(key_scope, :"run.post_events", marked) == {:error, :not_found}
      assert Access.may_serve?(gateway, marked)
    end

    test "of a node is held to its workspace, and to no gateway's rule", ctx do
      key_scope = key_scope(ctx.scope, node_fixture(ctx.scope, gateway_choice: "direct"))

      assert Access.check(key_scope, :"run.post_events", run_fixture(ctx.scope)) == :ok

      assert Access.check(key_scope, :"run.post_events", run_fixture(ctx.other)) ==
               {:error, :not_found}
    end
  end

  describe "may_serve?/2" do
    test "is false for no gateway", ctx do
      refute Access.may_serve?(nil, ctx.scope.workspace)
      refute Access.may_serve?(nil, run_fixture(ctx.scope))
      refute Access.may_serve?(nil, nil)
    end

    test "answers of a run as of its workspace", ctx do
      gateway = organisation_gateway_fixture(ctx.scope)

      assert Access.may_serve?(gateway, run_fixture(ctx.scope))
      refute Access.may_serve?(gateway, run_fixture(ctx.other))
      refute Access.may_serve?(node_fixture(ctx.scope), run_fixture(ctx.scope))
    end
  end

  describe "the credentials of a run" do
    @describetag needs: :factory

    @actions [:"secret.seal", :"run_credential.issue"]

    test "are a gateway's that may serve the run, at any level", ctx do
      for gateway_scope <- [
            key_scope(ctx.scope, gateway_fixture(ctx.scope)),
            key_scope(ctx.scope, organisation_gateway_fixture(ctx.scope)),
            Scope.for_access_key(installed_key_fixture(instance_gateway_fixture()).access_key)
          ],
          action <- @actions do
        assert Access.check(gateway_scope, action, run_fixture(ctx.scope)) == :ok
      end
    end

    test "are not found to a gateway that may not serve the run", ctx do
      for gateway_scope <- [
            key_scope(ctx.other, gateway_fixture(ctx.other)),
            key_scope(ctx.other, organisation_gateway_fixture(ctx.other))
          ],
          action <- @actions do
        assert Access.check(gateway_scope, action, run_fixture(ctx.scope)) == {:error, :not_found}
      end
    end

    test "are no pool's key, and no person's", ctx do
      run = run_fixture(ctx.scope)
      pool_scope = key_scope(ctx.scope, pool_fixture(ctx.scope))

      for action <- @actions do
        assert Access.check(pool_scope, action, run) == {:error, :forbidden}
        assert Access.check(ctx.scope, action, run) == {:error, :forbidden}
      end
    end

    test "issue/4 makes no call and writes no entry for a gateway that may not serve the run",
         ctx do
      run = run_fixture(ctx.scope)
      %{access_key: key} = access_key_fixture(ctx.other, node: gateway_fixture(ctx.other))
      key = Repo.preload(Repo.get!(AccessKey, key.id), [:workspace, :node])

      row = %Apiary.Runs.RunCredential{purpose: :work, connection_id: nil, adapter_id: nil}

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          WorkCredential.issue(run, row, key, System.os_time(:second))
        end)

      assert answer == {:error, :not_found}
      assert log =~ run.node_run_id
      refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "run_credential.issue")
    end

    test "record_issued/3 is not recorded for a gateway that may not serve the run", ctx do
      run = run_fixture(ctx.scope)
      %{access_key: key} = access_key_fixture(ctx.other, node: gateway_fixture(ctx.other))
      key = Repo.preload(Repo.get!(AccessKey, key.id), [:workspace, :node])

      assert WorkCredential.record_issued(key, run, %{issued: %{}, row: nil, place: nil}) ==
               {:error, :not_recorded}
    end
  end
end

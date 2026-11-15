defmodule Apiary.OrganisationGatewaysTest do
  # Gateways that live at an organisation, with no workspace: what they may serve, the
  # defaults they hold, their keys and runs, their deletion, the purges, and the schema
  # that keeps them.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Edition, EditionStubs, Gateways, Nodes}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Attach, Batch, Ingest, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  # A gateway of the scope's organisation with an active key, and that key as a verified
  # request carries it.
  defp keyed(scope, attrs \\ %{}) do
    gateway = organisation_gateway_fixture(scope, attrs)
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: gateway)
    %{gateway: reload(gateway), key: key, secret: secret}
  end

  defp other_workspace(scope) do
    workspace = workspace_fixture(scope.organisation)
    %{workspace: workspace, scope: workspace_scope(scope.user, workspace)}
  end

  defp entries(node) do
    Repo.all(
      from e in Entry,
        where: e.subject_kind == "node" and e.subject_id == ^node.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "making one" do
    test "lives at the organisation, with no workspace, and its entry is the organisation's",
         %{scope: scope} do
      assert {:ok, gateway} =
               Nodes.create_organisation_gateway(scope, %{
                 name: "edge",
                 url: "https://gateway.example:8443"
               })

      assert %Node{kind: :gateway, workspace_id: nil, gateway_choice: :direct} = gateway
      assert gateway.organisation_id == scope.organisation.id
      assert gateway.public_id =~ ~r/\Ang_/
      assert Gateways.level(gateway) == {:organisation, scope.organisation.id}

      assert [%Entry{action: "node.create", workspace_id: nil} = entry] = entries(gateway)
      assert entry.after["default_gateway"] == true
    end

    test "owners and admins make one; a member may not", %{scope: scope} do
      admin = member_fixture(scope, :admin)
      member = member_fixture(scope, :member)

      assert {:ok, _} =
               Nodes.create_organisation_gateway(admin.scope, %{
                 name: "edge",
                 url: "https://gateway.example"
               })

      assert {:error, :forbidden} =
               Nodes.create_organisation_gateway(member.scope, %{
                 name: "other",
                 url: "https://gateway.example"
               })
    end

    test "its name is unique among the organisation's gateways in use, apart from a workspace's",
         %{scope: scope} do
      organisation_gateway_fixture(scope, name: "edge")
      gateway_fixture(scope, name: "edge")

      assert {:error, changeset} =
               Nodes.create_organisation_gateway(scope, %{
                 name: "edge",
                 url: "https://gateway.example"
               })

      assert %{name: ["is already the name of a gateway in this organisation"]} =
               errors_on(changeset)
    end

    test "the organisation's gateways are listed and read at the organisation alone",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope, name: "b")
      other = organisation_gateway_fixture(scope, name: "a")
      workspace_gateway = gateway_fixture(scope)
      %{scope: stranger} = sign_up_fixture()

      assert Enum.map(Nodes.list_organisation_gateways(scope), & &1.id) == [other.id, gateway.id]
      assert Nodes.get_organisation_gateway(scope, gateway.public_id).id == gateway.id
      assert Nodes.get_organisation_gateway(scope, workspace_gateway.public_id) == nil
      assert Nodes.get_organisation_gateway(stranger, gateway.public_id) == nil
      assert Nodes.get_node(scope, gateway.public_id) == nil
      assert Nodes.list_organisation_gateways(stranger) == []

      # A member of the organisation reads them as an admin does.
      member = member_fixture(scope, :member)
      assert length(Nodes.list_organisation_gateways(member.scope)) == 2
      assert Nodes.get_organisation_gateway(member.scope, gateway.public_id).id == gateway.id
    end

    test "a workspace lists the organisation's gateways that may serve it, narrowed alike",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope, name: "edge-one")
      _other = organisation_gateway_fixture(scope, name: "other")

      assert Enum.map(Nodes.list_serving_gateways(scope), & &1.name) == ["edge-one", "other"]
      assert [%{id: id}] = Nodes.list_serving_gateways(scope, %{q: "edge"})
      assert id == gateway.id
      assert Nodes.list_serving_gateways(scope, %{kind: :node}) == []
    end
  end

  describe "the default" do
    test "the first is the organisation's default, a second is not", %{scope: scope} do
      first = organisation_gateway_fixture(scope)
      second = organisation_gateway_fixture(scope)

      assert first.default_gateway
      refute second.default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == first.id
    end

    test "a workspace's own default comes before its organisation's", %{scope: scope} do
      organisation = organisation_gateway_fixture(scope)
      %{scope: elsewhere} = other_workspace(scope)

      # Made after the organisation's, the workspace's gateway resolves already: not marked.
      workspace = gateway_fixture(scope)
      refute workspace.default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == organisation.id

      {:ok, _} = Nodes.make_default_gateway(scope, workspace)
      assert Gateways.default_gateway_for(scope.workspace).id == workspace.id
      assert Gateways.default_gateway_for(elsewhere.workspace).id == organisation.id
    end

    test "a workspace whose gateway is its default keeps it when the organisation gets one",
         %{scope: scope} do
      workspace = gateway_fixture(scope)
      assert workspace.default_gateway

      # A default resolves for the organisation's workspace, at a level before it, but none
      # at the organisation or after: the organisation's first gateway is its default.
      organisation = organisation_gateway_fixture(scope)
      assert organisation.default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == workspace.id
    end

    test "a person moves the mark among the organisation's gateways", %{scope: scope} do
      first = organisation_gateway_fixture(scope)
      second = organisation_gateway_fixture(scope)

      assert {:ok, %Node{default_gateway: true}} = Nodes.make_default_gateway(scope, second)
      refute reload(first).default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == second.id
      assert Enum.any?(entries(first), &(&1.action == "node.edit"))
    end

    test "the database allows an organisation one default among its gateways", %{scope: scope} do
      first = organisation_gateway_fixture(scope)
      second = organisation_gateway_fixture(scope)
      assert first.default_gateway

      assert {:error, changeset} = second |> Node.default_changeset(true) |> Repo.update()
      assert %{default_gateway: [_]} = errors_on(changeset)
    end

    test "a new node starts on the default the organisation resolves", %{scope: scope} do
      organisation_gateway_fixture(scope)
      node = node_fixture(scope)

      assert node.gateway_choice == :default
      assert {:error, :gateway_without_key} = Gateways.resolve(node)
    end
  end

  describe "what it may serve" do
    test "every workspace of its organisation, and none of another", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{workspace: second} = other_workspace(scope)
      %{scope: stranger} = sign_up_fixture()

      assert Apiary.Access.may_serve?(gateway, scope.workspace)
      assert Apiary.Access.may_serve?(gateway, second)
      refute Apiary.Access.may_serve?(gateway, stranger.workspace)

      assert gateway |> Gateways.serves() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([scope.workspace.id, second.id])

      deleted = %{gateway | deleted_at: DateTime.utc_now()}
      refute Apiary.Access.may_serve?(deleted, scope.workspace)
      assert Gateways.serves(deleted) == []
    end

    test "the choices of a node are by level: the workspace's, then the organisation's",
         %{scope: scope} do
      organisation = organisation_gateway_fixture(scope, name: "a-organisation")
      workspace = gateway_fixture(scope, name: "z-workspace")
      %{scope: stranger} = sign_up_fixture()
      _theirs = organisation_gateway_fixture(stranger)

      assert Enum.map(Gateways.gateway_choices(scope), & &1.id) == [workspace.id, organisation.id]

      node = node_fixture(scope, gateway_choice: "named", gateway_id: organisation.id)
      assert node.gateway_id == organisation.id
    end

    test "a node may name it from any workspace of the organisation", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{scope: elsewhere} = other_workspace(scope)

      assert {:ok, node} =
               Nodes.create_node(elsewhere, %{
                 kind: "node",
                 name: "builder",
                 gateway_choice: "named",
                 gateway_id: gateway.id
               })

      assert Gateways.chosen(node).id == gateway.id
    end
  end

  describe "a gateway of an organisation out of use" do
    # The organisation is held out of use (`Apiary.EditionStubs.OutOfUse`), neither
    # deleted nor marked.
    setup %{scope: scope} do
      %{gateway: gateway, key: gateway_key} = keyed(scope)
      %{access_key: key} = contract_key_fixture(scope)
      :ok = Edition.put_test_stub(EditionStubs.OutOfUse)
      %{gateway: gateway, gateway_key: gateway_key, key: key}
    end

    defp out_of_use(%{organisation: organisation}),
      do: Process.put(:out_of_use, [organisation.id])

    defp attach(gateway_key, run, run_key) do
      {:ok, body} = Attach.parse(attach_body(run_key))
      Attach.attach(gateway_key, run.node_run_id, body, %{instance_id: instance_id()})
    end

    defp post(gateway_key, run) do
      {_subject, [started]} = first_events(run.node_run_id)
      {:ok, batch} = Batch.parse(Jason.encode!([started]))
      Ingest.ingest(gateway_key, batch, %{contract_version: 1, instance_id: instance_id()})
    end

    test "its key verifies, and acts for no run of its organisation's workspaces",
         %{scope: scope, gateway: gateway, gateway_key: gateway_key, key: key} do
      assert Gateways.chosen(key.node).id == gateway.id

      {:ok, %{run: attached, run_key: attached_key}} =
        register_run(key, gateway_registration(), instance_id())

      {:ok, %{run: waiting, run_key: waiting_key}} =
        register_run(key, gateway_registration(), instance_id())

      assert {:ok, _} = attach(gateway_key, attached, attached_key)

      out_of_use(scope)
      assert {:ok, verified} = AccessKeys.fetch_for_verification(gateway_key.key_id)
      assert verified.node.id == gateway.id
      assert AccessKeys.active_key?(gateway)

      assert attach(verified, waiting, waiting_key) == {:error, :unauthorized}
      assert {:error, :unauthorized} = post(verified, attached)
      assert Repo.get!(Run, attached.id).event_count == 0

      assert Apiary.Runs.Registration.fetch(verified, attached.node_run_id, instance_id()) ==
               {:error, :not_found}

      # The node of the organisation's workspace is out of use: its key fails.
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end

    test "a node or a node pool of an organisation out of use is not verified", %{
      scope: scope,
      key: key
    } do
      out_of_use(scope)
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end

    test "its key is refused once its organisation is marked for deletion",
         %{scope: scope, gateway: gateway, gateway_key: gateway_key, key: key} do
      {:ok, _} = Apiary.Deletion.delete_organisation(scope, scope.organisation.slug)

      assert AccessKeys.fetch_for_verification(gateway_key.key_id) == :error
      refute AccessKeys.active_key?(gateway)

      # A node that goes through it finds it without a key.
      assert {:error, :gateway_without_key} = Gateways.resolve(key.node)
    end
  end

  describe "deleting one" do
    test "refused while a node of any workspace of the organisation names it or defaults to it",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{scope: elsewhere} = other_workspace(scope)
      defaulting = node_fixture(scope)
      named = node_fixture(elsewhere, gateway_choice: "named", gateway_id: gateway.id)

      assert {:error, {:gateway_in_use, %{nodes: nodes}}} = Nodes.delete_node(scope, gateway)
      assert Enum.sort(Enum.map(nodes, & &1.id)) == Enum.sort([defaulting.id, named.id])
      assert reload(gateway).deleted_at == nil
    end

    test "a node of a workspace with a default at the workspace does not block the organisation's",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      node = node_fixture(scope)
      assert Gateways.chosen(node).id == gateway.id

      own = gateway_fixture(scope)
      {:ok, _} = Nodes.make_default_gateway(scope, own)
      assert Gateways.delete_blockers(gateway) == %{nodes: [], runs: []}
    end

    test "the oldest left becomes the default, its keys are revoked, and the mark is in the trail",
         %{scope: scope} do
      %{gateway: first, key: key} = keyed(scope)
      second = organisation_gateway_fixture(scope)
      third = organisation_gateway_fixture(scope)
      assert first.default_gateway

      assert {:ok, %Node{deleted_at: %DateTime{}, default_gateway: false}} =
               Nodes.delete_node(scope, first)

      assert reload(second).default_gateway
      refute reload(third).default_gateway
      assert Repo.get!(AccessKey, key.id).revoked_at
      assert Enum.any?(entries(second), &(&1.action == "node.edit"))
    end

    test "a member may not delete one, nor make it the default", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      second = organisation_gateway_fixture(scope)
      member = member_fixture(scope, :member)

      assert {:error, :forbidden} = Nodes.delete_node(member.scope, gateway)
      assert {:error, :forbidden} = Nodes.make_default_gateway(member.scope, second)
      assert {:error, :forbidden} = Nodes.update_node(member.scope, gateway, %{name: "x"})
    end

    test "a change from the scope of another organisation finds nothing", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{scope: stranger} = sign_up_fixture()

      assert {:error, :not_found} = Nodes.delete_node(stranger, gateway)
      assert {:error, :not_found} = Nodes.update_node(stranger, gateway, %{name: "x"})
    end

    test "renamed and its address changed, at the organisation", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)

      assert {:ok, %Node{name: "edge-2", url: "https://edge.example"}} =
               Nodes.update_node(scope, gateway, %{name: "edge-2", url: "https://edge.example"})
    end
  end

  describe "its keys" do
    test "a key made in a browser and one enrolled have no workspace, and verify",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{access_key: browser} = node_key_fixture(scope, gateway)
      %{access_key: enrolled} = enrolled_key_fixture(scope, gateway)

      for key <- [browser, enrolled] do
        assert key.workspace_id == nil
        assert key.organisation_id == scope.organisation.id
        assert {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
        assert verified.workspace == nil
        assert verified.node.id == gateway.id
        assert %Scope{workspace: nil, access_key: ^verified} = Scope.for_access_key(verified)
      end

      assert AccessKeys.active_key?(gateway)
      assert [%EnrolmentCode{workspace_id: nil}] = Repo.all(EnrolmentCode)

      assert Enum.map(AccessKeys.list_for_node(scope, gateway), & &1.id) |> Enum.sort() ==
               Enum.sort([browser.id, enrolled.id])
    end

    test "a member may not make a code or add a key; another organisation finds nothing",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      member = member_fixture(scope, :member)
      %{scope: stranger} = sign_up_fixture()

      assert {:error, :forbidden} = AccessKeys.create_enrolment_code(member.scope, gateway, %{})
      assert {:error, :not_found} = AccessKeys.create_enrolment_code(stranger, gateway, %{})
    end

    test "revoked from the organisation, and an outstanding code cancelled", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, gateway)
      {:ok, code, _plain} = AccessKeys.create_enrolment_code(scope, gateway, %{})

      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} =
               AccessKeys.revoke_access_key(scope, key)

      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} =
               AccessKeys.cancel_code(scope, code)

      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end

    test "its instances are recorded at the organisation, and read there", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      :ok = Nodes.subscribe(scope, :organisation)
      :ok = Nodes.seen(gateway, %{instance_id: "i_edge-1"})

      assert_receive {:nodes_touched, organisation_id}
      assert organisation_id == scope.organisation.id

      assert %Instance{workspace_id: nil} = Nodes.get_instance(scope, gateway, "i_edge-1")

      assert %{last: %Instance{node_instance_id: "i_edge-1"}} =
               Map.fetch!(Nodes.activity(scope, [gateway]), gateway.id)
    end
  end

  describe "its runs" do
    setup %{scope: scope} do
      %{gateway: gateway, key: gateway_key} = keyed(scope)
      %{scope: elsewhere} = other_workspace(scope)
      %{access_key: key, node: node} = contract_key_fixture(elsewhere)
      assert node.gateway_choice == :default
      %{gateway: gateway, gateway_key: gateway_key, key: key, elsewhere: elsewhere}
    end

    test "a node of any workspace registers through it; it attaches the run and posts its events",
         %{gateway: gateway, gateway_key: gateway_key, key: key, elsewhere: elsewhere} do
      {:ok, %{run: run, run_key: run_key}} =
        register_run(key, gateway_registration(), instance_id())

      assert run.gateway_id == gateway.id
      assert run.workspace_id == elsewhere.workspace.id

      {:ok, body} = Attach.parse(attach_body(run_key))

      assert {:ok, %{run: %Run{attached_at: %DateTime{}}, repeated: false}} =
               Attach.attach(gateway_key, run.node_run_id, body, %{instance_id: instance_id()})

      {_subject, [started]} = first_events(run.node_run_id)
      {:ok, batch} = Batch.parse(Jason.encode!([started]))

      assert {:ok, %{status: 202, inserted: 1}} =
               Ingest.ingest(gateway_key, batch, %{
                 contract_version: 1,
                 instance_id: instance_id()
               })

      assert Repo.get!(Run, run.id).workspace_id == elsewhere.workspace.id
      assert Gateways.delete_blockers(gateway).runs |> Enum.map(& &1.id) == [run.id]
    end

    test "its key registers no run", %{gateway_key: gateway_key} do
      assert {:error, :gateway_key} =
               register_run(gateway_key, gateway_registration(), instance_id())
    end

    test "its key's batch for a run it did not attach opens none", %{gateway_key: gateway_key} do
      {subject, events} = first_events()
      {:ok, batch} = Batch.parse(Jason.encode!(events))

      assert {:error, _refused} =
               Ingest.ingest(gateway_key, batch, %{
                 contract_version: 1,
                 instance_id: instance_id()
               })

      refute Repo.exists?(from r in Run, where: r.node_run_id == ^subject)
    end
  end

  describe "the purges" do
    test "a workspace's leaves the organisation's gateways and their keys", %{scope: scope} do
      %{gateway: gateway, key: key} = keyed(scope)
      %{workspace: workspace} = other_workspace(scope)

      {:ok, _} = Apiary.Deletion.delete_workspace(scope, workspace.id, workspace.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Apiary.Deletion.purge_workspace(Scope.for_instance(scope.organisation, workspace))

      assert reload(gateway).deleted_at == nil
      assert Repo.get(AccessKey, key.id)
    end

    test "an organisation's takes them, with their keys, codes and instances", %{scope: scope} do
      %{gateway: gateway, key: key} = keyed(scope)
      {:ok, _code, _plain} = AccessKeys.create_enrolment_code(scope, gateway, %{})
      instance_fixture(gateway)

      assert {:ok, :purged} = Apiary.Deletion.purge_now(scope.organisation)

      assert Repo.get(Node, gateway.id) == nil
      assert Repo.get(AccessKey, key.id) == nil
      refute Repo.exists?(from c in EnrolmentCode, where: c.node_id == ^gateway.id)
      refute Repo.exists?(from i in Instance, where: i.node_id == ^gateway.id)
    end
  end

  describe "the schema" do
    test "a node without a workspace is a gateway", %{scope: scope} do
      node = node_fixture(scope)

      # A row like the node's, with no workspace: its place is fixed once made, so the
      # check is met as a row is inserted.
      row =
        Node.__schema__(:fields)
        |> then(&Map.take(node, &1))
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          public_id: "nd_" <> String.duplicate("a", 16),
          name: "placeless",
          workspace_id: nil
        })

      assert_raise Postgrex.Error, ~r/nodes_place_check/, fn ->
        Repo.insert_all(Node, [row])
      end
    end

    test "an organisation's names and its default are unique among its gateways in use",
         %{scope: scope} do
      first = organisation_gateway_fixture(scope, name: "edge")
      second = organisation_gateway_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_organisation_live_name_index/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^second.id), set: [name: "edge"])
      end

      assert_raise Postgrex.Error, ~r/nodes_organisation_default_gateway_index/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^second.id), set: [default_gateway: true])
      end

      # Deleted, its name is free again.
      Repo.update_all(from(n in Node, where: n.id == ^first.id),
        set: [deleted_at: DateTime.utc_now(), default_gateway: false]
      )

      assert {1, _} =
               Repo.update_all(from(n in Node, where: n.id == ^second.id), set: [name: "edge"])
    end

    test "a key, a code or an instance without a workspace is of a node without one",
         %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      instance = instance_fixture(node)
      {:ok, code, _plain} = AccessKeys.create_enrolment_code(scope, node, %{})

      for {schema, id} <- [{AccessKey, key.id}, {Instance, instance.id}, {EnrolmentCode, code.id}] do
        assert_raise Postgrex.Error, ~r/node_place_matches/, fn ->
          Repo.update_all(from(r in schema, where: r.id == ^id), set: [workspace_id: nil])
        end
      end
    end

    test "a node's place is fixed: no workspace is given to or taken from it",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      node = node_fixture(scope)

      for {id, workspace_id} <- [{gateway.id, scope.workspace.id}, {node.id, nil}] do
        assert_raise Postgrex.Error, ~r/nodes_place_fixed/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^id), set: [workspace_id: workspace_id])
        end
      end

      other = workspace_fixture(scope.organisation)

      assert_raise Postgrex.Error, ~r/nodes_place_fixed/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [workspace_id: other.id])
      end
    end

    test "a key is of its node's organisation", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      %{scope: stranger} = sign_up_fixture()
      %{access_key: key} = node_key_fixture(scope, gateway)

      assert_raise Postgrex.Error,
                   ~r/node_place_matches|access_keys_node_organisation_fkey|access_keys_organisation_id_fkey/,
                   fn ->
                     Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
                       set: [organisation_id: stranger.organisation.id]
                     )
                   end
    end

    test "a row of a workspace keeps its workspace's node", %{scope: scope} do
      node = node_fixture(scope)
      %{workspace: other} = other_workspace(scope)
      %{access_key: key} = node_key_fixture(scope, node)

      assert_raise Postgrex.Error, ~r/access_keys_node_id_fkey/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
          set: [workspace_id: other.id]
        )
      end
    end
  end
end

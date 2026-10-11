defmodule Apiary.GatewaysTest do
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Gateways, Nodes}
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Attach, Liveness, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp entries(node) do
    Repo.all(
      from e in Entry,
        where: e.subject_kind == "node" and e.subject_id == ^node.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  # A gateway that may serve: one with an active key.
  defp keyed_gateway(scope, attrs \\ %{}) do
    gateway = gateway_fixture(scope, attrs)
    node_key_fixture(scope, gateway)
    reload(gateway)
  end

  # A second workspace of the scope's organisation, with its scope.
  defp other_workspace(scope) do
    workspace = workspace_fixture(scope.organisation)
    %{workspace: workspace, scope: workspace_scope(scope.user, workspace)}
  end

  describe "making a gateway" do
    test "a gateway of the workspace, ng_, with its address and no limit", %{scope: scope} do
      assert {:ok, gateway} =
               Nodes.create_node(scope, %{
                 kind: "gateway",
                 name: "edge",
                 url: "https://gateway.example:8443",
                 instance_limit: 5,
                 gateway_choice: "default"
               })

      assert %Node{kind: :gateway, instance_limit: nil, url: "https://gateway.example:8443"} =
               gateway

      assert gateway.public_id =~ ~r/\Ang_[0-9a-hjkmnp-tv-z]{16}\z/
      assert gateway.gateway_choice == :direct
      assert gateway.gateway_id == nil
      assert gateway.workspace_id == scope.workspace.id

      assert [entry] = entries(gateway)
      assert entry.action == "node.create"

      assert entry.after == %{
               "name" => "edge",
               "kind" => "gateway",
               "public_id" => gateway.public_id,
               "instance_limit" => nil,
               "url" => "https://gateway.example:8443",
               "default_gateway" => true
             }
    end

    test "the database holds a gateway's address to https too", %{scope: scope} do
      gateway = gateway_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_url_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^gateway.id),
          set: [url: "http://localhost:8080"]
        )
      end
    end

    test "its address is https, with a host and a port alone", %{scope: scope} do
      for url <- ~w(https://gateway.example https://10.0.0.7:8443 https://localhost:8443
                    https://127.0.0.1 https://[2001:db8::1]) do
        assert {:ok, %Node{url: ^url}} =
                 Nodes.create_node(scope, %{kind: "gateway", name: unique_node_name(), url: url}),
               url
      end

      for url <- ~w(http://gateway.example http://10.0.0.7 http://localhost:8080
                    http://127.0.0.1 http://[::1]:8080 ftp://gateway.example) do
        assert {:error, changeset} =
                 Nodes.create_node(scope, %{kind: "gateway", name: "x", url: url})

        assert %{url: ["must start with https://"]} =
                 errors_on(changeset),
               url
      end

      for url <- ~w(https://gateway.example/ https://gateway.example/v1 https://a@gateway.example
                    https://gateway.example?x=1 https://gateway.example#x gateway.example
                    https:// https://gateway.example:0 https://gateway.example:70000
                    HTTPS://gateway.example) ++ ["https://gate way.example"] do
        assert {:error, changeset} =
                 Nodes.create_node(scope, %{kind: "gateway", name: "x", url: url})

        assert %{url: ["must be a scheme and a host, with a port if needed, and nothing more"]} =
                 errors_on(changeset),
               url
      end

      long = "https://" <> String.duplicate("a", 2041) <> ".example"

      assert {:error, changeset} =
               Nodes.create_node(scope, %{kind: "gateway", name: "x", url: long})

      assert "should be at most 2048 character(s)" in errors_on(changeset).url

      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "gateway", name: "x"})
      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "a node and a pool have no address", %{scope: scope} do
      node = node_fixture(scope, url: "https://gateway.example")
      pool = pool_fixture(scope, url: "https://gateway.example")
      assert node.url == nil
      assert pool.url == nil
    end

    test "its address changes; the change is in the trail", %{scope: scope} do
      gateway = gateway_fixture(scope)

      assert {:ok, %Node{url: "https://other.example"} = changed} =
               Nodes.update_node(scope, gateway, %{
                 url: "https://other.example",
                 gateway_choice: "default"
               })

      assert changed.gateway_choice == :direct

      assert [_created, edit] = entries(gateway)
      assert edit.action == "node.edit"
      assert edit.before == %{"url" => "https://gateway.example"}
      assert edit.after == %{"url" => "https://other.example"}

      assert {:error, changeset} =
               Nodes.update_node(scope, changed, %{url: "http://other.example"})

      assert %{url: [_]} = errors_on(changeset)
    end
  end

  describe "the default mark" do
    test "the first gateway is the default; a second moves no node", %{scope: scope} do
      first = keyed_gateway(scope)
      assert first.default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == first.id

      pool = pool_fixture(scope, gateway_choice: "default")
      assert {:gateway, %Node{id: id}} = Gateways.resolve(pool)
      assert id == first.id

      second = keyed_gateway(scope)
      refute second.default_gateway
      assert reload(first).default_gateway
      assert {:gateway, %Node{id: ^id}} = Gateways.resolve(reload(pool))
    end

    test "a gateway of another workspace is not this one's default", %{scope: scope} do
      %{scope: there, workspace: workspace} = other_workspace(scope)
      gateway = gateway_fixture(scope)
      elsewhere = gateway_fixture(there)

      # Each is the first of its own workspace.
      assert gateway.default_gateway
      assert elsewhere.default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == gateway.id
      assert Gateways.default_gateway_for(workspace).id == elsewhere.id
    end

    test "a person moves the mark, and the change of each is in the trail", %{scope: scope} do
      first = keyed_gateway(scope)
      second = keyed_gateway(scope)
      pool = pool_fixture(scope, gateway_choice: "default")

      assert {:ok, %Node{default_gateway: true}} = Nodes.make_default_gateway(scope, second)
      refute reload(first).default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == second.id

      # The nodes on the default resolve to the new one.
      assert {:gateway, %Node{id: id}} = Gateways.resolve(reload(pool))
      assert id == second.id

      assert [_created, off] = entries(first)
      assert off.action == "node.edit"

      assert {off.before, off.after} ==
               {%{"default_gateway" => true}, %{"default_gateway" => false}}

      assert [_created, on] = entries(second)

      assert {on.before, on.after} ==
               {%{"default_gateway" => false}, %{"default_gateway" => true}}

      # Again: nothing changes, nothing is recorded.
      assert {:ok, %Node{default_gateway: true}} = Nodes.make_default_gateway(scope, second)
      assert length(entries(second)) == 2
    end

    test "only a gateway of the workspace, in use, is marked", %{scope: scope} do
      node = node_fixture(scope)
      assert Nodes.make_default_gateway(scope, node) == {:error, :not_found}

      %{scope: there} = other_workspace(scope)
      elsewhere = gateway_fixture(there)
      assert Nodes.make_default_gateway(scope, elsewhere) == {:error, :not_found}

      %{scope: member} = member_fixture(scope, :member)
      gateway = gateway_fixture(scope)
      assert Nodes.make_default_gateway(member, gateway) == {:error, :forbidden}
    end
  end

  describe "a node's choice" do
    test "a new node or pool starts on the default when one resolves, else direct",
         %{scope: scope} do
      assert node_fixture(scope).gateway_choice == :direct
      assert pool_fixture(scope).gateway_choice == :direct

      gateway_fixture(scope)
      assert node_fixture(scope).gateway_choice == :default
      assert pool_fixture(scope).gateway_choice == :default

      # In a workspace no default resolves for, direct.
      %{scope: there} = other_workspace(scope)
      assert node_fixture(there).gateway_choice == :direct
      assert pool_fixture(there).gateway_choice == :direct

      assert [entry] = entries(node_fixture(scope))
      assert entry.after["gateway_choice"] == "default"
    end

    test "a choice given at creation wins", %{scope: scope} do
      gateway = gateway_fixture(scope)

      assert node_fixture(scope, gateway_choice: "direct").gateway_choice == :direct

      assert {:ok, %Node{gateway_choice: :direct}} =
               Nodes.create_node(scope, %{
                 "kind" => "pool",
                 "name" => "ci",
                 "gateway_choice" => "direct"
               })

      named = pool_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
      assert {named.gateway_choice, named.gateway_id} == {:named, gateway.id}
    end

    test "the database's refusals come back as errors, not raised", %{scope: scope} do
      first = gateway_fixture(scope)
      second = gateway_fixture(scope)
      pool = pool_fixture(scope, gateway_choice: "direct")

      # Past the checks of `Apiary.Nodes`: the database refuses, the changeset says so.
      assert {:error, changeset} = second |> Node.default_changeset(true) |> Repo.update()
      assert %{default_gateway: [_]} = errors_on(changeset)

      assert {:error, changeset} = pool |> Node.default_changeset(true) |> Repo.update()
      assert %{default_gateway: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               pool
               |> Node.changeset(%{gateway_choice: "named", gateway_id: pool.id})
               |> Repo.update()

      assert %{gateway_id: [_]} = errors_on(changeset)
      assert reload(first).default_gateway
    end

    test "names a gateway it may use, and records it", %{scope: scope} do
      gateway = gateway_fixture(scope)

      assert {:ok, pool} =
               Nodes.create_node(scope, %{
                 kind: "pool",
                 name: "ci",
                 gateway_choice: "named",
                 gateway_id: gateway.id
               })

      assert {pool.gateway_choice, pool.gateway_id} == {:named, gateway.id}
      assert [entry] = entries(pool)
      assert entry.after["gateway_choice"] == "named"
      assert entry.after["gateway_id"] == gateway.id
    end

    test "named must be one of the gateway choices", %{scope: scope} do
      %{scope: there} = other_workspace(scope)
      elsewhere = gateway_fixture(there)
      node = node_fixture(scope)
      deleted = gateway_fixture(scope)
      {:ok, _} = Nodes.delete_node(scope, deleted)

      assert Gateways.gateway_choices(scope) == []

      for id <- [elsewhere.id, node.id, deleted.id, Ecto.UUID.generate()] do
        assert {:error, changeset} =
                 Nodes.update_node(scope, node, %{gateway_choice: "named", gateway_id: id})

        assert %{gateway_id: ["is not a gateway this node may use"]} = errors_on(changeset)
      end

      assert {:error, changeset} = Nodes.update_node(scope, node, %{gateway_choice: "named"})
      assert %{gateway_id: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Nodes.update_node(scope, node, %{gateway_choice: "through"})
      assert %{gateway_choice: ["is invalid"]} = errors_on(changeset)
    end

    test "the gateway choices are the workspace's gateways in use, by name", %{scope: scope} do
      b = gateway_fixture(scope, name: "b-edge")
      a = gateway_fixture(scope, name: "a-edge")
      gone = gateway_fixture(scope, name: "c-edge")
      {:ok, _} = Nodes.delete_node(scope, gone)
      node_fixture(scope)
      %{scope: there} = other_workspace(scope)
      gateway_fixture(there)

      assert Enum.map(Gateways.gateway_choices(scope), & &1.id) == [a.id, b.id]
    end

    test "default needs a default that resolves", %{scope: scope} do
      node = node_fixture(scope)

      assert {:error, changeset} = Nodes.update_node(scope, node, %{gateway_choice: "default"})

      assert %{gateway_choice: ["has no default gateway in this workspace"]} =
               errors_on(changeset)

      gateway_fixture(scope)

      assert {:ok, %Node{gateway_choice: :default}} =
               Nodes.update_node(scope, node, %{gateway_choice: "default"})
    end

    test "changes, and the change is in the trail; direct drops the gateway", %{scope: scope} do
      gateway = gateway_fixture(scope)
      node = node_fixture(scope, gateway_choice: "direct")

      {:ok, named} =
        Nodes.update_node(scope, node, %{gateway_choice: "named", gateway_id: gateway.id})

      {:ok, direct} =
        Nodes.update_node(scope, named, %{gateway_choice: "direct", gateway_id: gateway.id})

      assert {direct.gateway_choice, direct.gateway_id} == {:direct, nil}

      assert [_created, to_named, to_direct] = entries(node)

      assert {to_named.before, to_named.after} ==
               {%{"gateway_choice" => "direct", "gateway_id" => nil},
                %{"gateway_choice" => "named", "gateway_id" => gateway.id}}

      assert {to_direct.before, to_direct.after} ==
               {%{"gateway_choice" => "named", "gateway_id" => gateway.id},
                %{"gateway_choice" => "direct", "gateway_id" => nil}}
    end

    test "a gateway chooses none", %{scope: scope} do
      first = gateway_fixture(scope)
      gateway = gateway_fixture(scope)

      assert {:ok, changed} =
               Nodes.update_node(scope, gateway, %{gateway_choice: "named", gateway_id: first.id})

      assert {changed.gateway_choice, changed.gateway_id} == {:direct, nil}
    end
  end

  describe "resolve/1" do
    test "direct", %{scope: scope} do
      keyed_gateway(scope)
      assert Gateways.resolve(node_fixture(scope, gateway_choice: "direct")) == :direct
    end

    test "a named gateway, while it may serve and has a key", %{scope: scope} do
      gateway = keyed_gateway(scope)
      other = keyed_gateway(scope)
      pool = pool_fixture(scope, gateway_choice: "named", gateway_id: other.id)

      assert {:gateway, %Node{id: id}} = Gateways.resolve(pool)
      assert id == other.id
      refute id == gateway.id
    end

    test "the default, most specific first", %{scope: scope} do
      gateway = keyed_gateway(scope)
      node = node_fixture(scope, gateway_choice: "default")
      assert {:gateway, %Node{id: id}} = Gateways.resolve(node)
      assert id == gateway.id
    end

    test "no default: refused", %{scope: scope} do
      gateway = gateway_fixture(scope)
      node = node_fixture(scope, gateway_choice: "default")

      # The mark gone, by a write no function makes, so that nothing resolves.
      Repo.update_all(from(n in Node, where: n.id == ^gateway.id), set: [default_gateway: false])
      assert Gateways.default_gateway_for(scope.workspace) == nil
      assert Gateways.resolve(node) == {:error, :no_default_gateway}
    end

    test "a gateway with no active key: refused", %{scope: scope} do
      gateway = gateway_fixture(scope)
      named = pool_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
      default = pool_fixture(scope, gateway_choice: "default")

      assert Gateways.resolve(named) == {:error, :gateway_without_key}
      assert Gateways.resolve(default) == {:error, :gateway_without_key}

      %{access_key: key} = node_key_fixture(scope, gateway)
      assert {:gateway, _} = Gateways.resolve(named)

      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      assert Gateways.resolve(named) == {:error, :gateway_without_key}
      assert Gateways.resolve(default) == {:error, :gateway_without_key}
    end

    test "a named gateway that can no longer serve: refused", %{scope: scope} do
      gateway = keyed_gateway(scope)
      pool = pool_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)

      # The pool as if it were of another workspace, which the gateway may not serve.
      %{workspace: workspace} = other_workspace(scope)
      elsewhere = %{pool | workspace_id: workspace.id, workspace: workspace}

      assert Gateways.resolve(pool) |> elem(0) == :gateway
      refute Gateways.may_serve?(gateway, workspace)
      assert Gateways.resolve(elsewhere) == {:error, :gateway_not_serving}
    end

    test "a named gateway that is deleted or gone: refused", %{scope: scope} do
      gateway = keyed_gateway(scope)
      pool = pool_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)

      Repo.update_all(from(n in Node, where: n.id == ^gateway.id),
        set: [deleted_at: DateTime.utc_now(), default_gateway: false]
      )

      assert Gateways.resolve(pool) == {:error, :gateway_not_serving}
      assert Gateways.resolve(%{pool | gateway_id: nil}) == {:error, :gateway_not_serving}
    end

    test "a gateway goes through none", %{scope: scope} do
      assert Gateways.resolve(keyed_gateway(scope)) == {:error, :gateway_key}
    end
  end

  describe "where a gateway stands" do
    test "it may serve its own workspace alone", %{scope: scope} do
      gateway = gateway_fixture(scope)
      %{workspace: workspace} = other_workspace(scope)

      assert Gateways.may_serve?(gateway, scope.workspace)
      refute Gateways.may_serve?(gateway, workspace)
      refute Gateways.may_serve?(node_fixture(scope, gateway_choice: "direct"), scope.workspace)

      assert Enum.map(Gateways.serves(gateway), & &1.id) == [scope.workspace.id]
      assert Gateways.serves(node_fixture(scope, gateway_choice: "direct")) == []

      {:ok, deleted} = Nodes.delete_node(scope, gateway)
      refute Gateways.may_serve?(deleted, scope.workspace)
      assert Gateways.serves(deleted) == []
    end

    test "of another organisation, it serves nothing here", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      gateway = gateway_fixture(other)
      refute Gateways.may_serve?(gateway, scope.workspace)
    end
  end

  describe "deleting a gateway" do
    test "refused while nodes name it, naming them", %{scope: scope} do
      gateway = gateway_fixture(scope)
      _other = gateway_fixture(scope)
      a = pool_fixture(scope, name: "a-pool", gateway_choice: "named", gateway_id: gateway.id)
      b = node_fixture(scope, name: "b-node", gateway_choice: "named", gateway_id: gateway.id)

      # Not the default's nodes: the default is this gateway, and none chose the default.
      assert {:error, {:gateway_in_use, %{nodes: nodes}}} =
               Nodes.delete_node(scope, gateway)

      assert Enum.map(nodes, & &1.id) == [a.id, b.id]
      assert reload(gateway).deleted_at == nil

      {:ok, _} = Nodes.update_node(scope, a, %{gateway_choice: "direct"})
      {:ok, _} = Nodes.delete_node(scope, b)
      assert {:ok, _deleted} = Nodes.delete_node(scope, gateway)
    end

    test "refused while nodes on the default resolve to it", %{scope: scope} do
      gateway = gateway_fixture(scope)
      other = gateway_fixture(scope)
      node = node_fixture(scope, gateway_choice: "default")

      assert Gateways.delete_blockers(gateway) == %{nodes: [reload(node)], runs: []}
      assert Gateways.delete_blockers(other) == %{nodes: [], runs: []}

      assert {:error, {:gateway_in_use, %{nodes: [%Node{id: id}]}}} =
               Nodes.delete_node(scope, gateway)

      assert id == node.id

      # The other one, not the default, goes; then the mark moves, and the first goes too.
      third = gateway_fixture(scope)
      assert {:ok, _} = Nodes.delete_node(scope, other)
      {:ok, _} = Nodes.make_default_gateway(scope, third)
      assert Gateways.delete_blockers(gateway) == %{nodes: [], runs: []}
      assert {:ok, _} = Nodes.delete_node(scope, gateway)
      assert reload(third).default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == third.id
    end

    test "a deleted node does not hold it", %{scope: scope} do
      gateway = gateway_fixture(scope)
      node = node_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
      {:ok, _} = Nodes.delete_node(scope, node)
      assert {:ok, _} = Nodes.delete_node(scope, gateway)
    end

    test "the default goes when nothing points to it, and the oldest left is the default",
         %{scope: scope} do
      first = gateway_fixture(scope)
      second = gateway_fixture(scope)
      third = gateway_fixture(scope)
      assert first.default_gateway

      # Made in this order, the second is older than the third.
      Repo.update_all(from(n in Node, where: n.id == ^third.id),
        set: [inserted_at: DateTime.add(second.inserted_at, 1, :second)]
      )

      assert {:ok, deleted} = Nodes.delete_node(scope, first)
      refute deleted.default_gateway
      assert reload(second).default_gateway
      refute reload(third).default_gateway
      assert Gateways.default_gateway_for(scope.workspace).id == second.id

      assert [_created, delete] = entries(first)
      assert delete.action == "node.delete"
      assert delete.details["default_gateway"] == true

      assert [_created, marked] = entries(second)
      assert marked.action == "node.edit"
      assert marked.after == %{"default_gateway" => true}
      assert marked.actor_id == scope.user.id
    end

    test "a gateway that was not the default leaves the default where it is", %{scope: scope} do
      first = gateway_fixture(scope)
      second = gateway_fixture(scope)
      assert {:ok, _} = Nodes.delete_node(scope, second)
      assert Gateways.default_gateway_for(scope.workspace).id == first.id
    end

    test "the last one goes, and nothing is the default", %{scope: scope} do
      gateway = gateway_fixture(scope)
      assert {:ok, _} = Nodes.delete_node(scope, gateway)
      assert Gateways.default_gateway_for(scope.workspace) == nil

      # The next one made is the default again.
      assert gateway_fixture(scope).default_gateway
    end

    test "its keys are revoked", %{scope: scope} do
      gateway = gateway_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, gateway)
      assert {:ok, _} = Nodes.delete_node(scope, gateway)
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
      refute AccessKeys.active_key?(gateway)
    end
  end

  describe "deleting a gateway runs go through" do
    # A gateway with a key, and a node of the workspace that names it, with a key of its
    # own: the node registers runs through the gateway, and the gateway attaches them.
    defp through(scope) do
      %{access_key: gateway_key} = contract_key_fixture(scope, node: gateway_fixture(scope))
      gateway = reload(gateway_key.node)
      node = node_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
      %{access_key: node_key} = contract_key_fixture(scope, node: node)
      %{gateway: gateway, gateway_key: gateway_key, node: node, node_key: node_key}
    end

    defp register(%{node_key: key}) do
      {:ok, %{run: run, run_key: run_key}} =
        register_run(key, gateway_registration(), instance_id())

      {run, run_key}
    end

    defp attach(%{gateway_key: key}, {run, run_key}) do
      {:ok, body} = Attach.parse(attach_body(run_key))
      {:ok, %{run: attached}} = Attach.attach(key, run.run_id, body, %{})
      attached
    end

    # The node goes directly from now on; the runs it registered keep their gateway.
    defp go_direct(scope, %{node: node}) do
      {:ok, _} = Nodes.update_node(scope, reload(node), %{gateway_choice: "direct"})
      :ok
    end

    defp set(run, changes),
      do: Repo.update_all(from(r in Run, where: r.id == ^run.id), set: changes)

    defp ids(runs), do: Enum.map(runs, & &1.id)

    defp reload_run(run), do: Repo.get!(Run, run.id)

    test "refused while a run it attached is live, naming the run", %{scope: scope} do
      through = through(scope)
      run = attach(through, register(through))
      :ok = go_direct(scope, through)

      assert {:error, {:gateway_in_use, %{nodes: [], runs: [%Run{id: id}]}}} =
               Nodes.delete_node(scope, through.gateway)

      assert id == run.id
      assert reload(through.gateway).deleted_at == nil
    end

    test "refused while a run waits for it to attach, naming the run", %{scope: scope} do
      through = through(scope)
      {run, _run_key} = register(through)
      :ok = go_direct(scope, through)

      assert run.attached_at == nil

      assert {:error, {:gateway_in_use, %{nodes: [], runs: [%Run{id: id}]}}} =
               Nodes.delete_node(scope, through.gateway)

      assert id == run.id
    end

    test "a run that ended, was lost, or whose attach window closed does not hold it",
         %{scope: scope} do
      through = through(scope)
      now = DateTime.utc_now()

      completed = attach(through, register(through))
      set(completed, state: "completed", exited_at: now)
      exited = attach(through, register(through))
      set(exited, exited_at: now)
      given_outcome = attach(through, register(through))

      set(given_outcome,
        outcome_state: "succeeded",
        outcome_time: now,
        outcome_received_at: now,
        outcome_digest: :crypto.hash(:sha256, "outcome")
      )

      pruned = attach(through, register(through))
      set(pruned, events_pruned_at: now)
      lost_attached = attach(through, register(through))
      set(lost_attached, state: "lost", lost_at: now)
      {lost_waiting, _run_key} = register(through)
      set(lost_waiting, state: "lost", lost_at: now)
      {expired, _run_key} = register(through)

      set(expired,
        run_key_issued_at: DateTime.add(now, -601, :second),
        attach_by: DateTime.add(now, -1, :second)
      )

      {cancelled_old_name, _run_key} = register(through)
      set(cancelled_old_name, state: "timed_out")
      # Refused at its start: failed, with no exit and no outcome, as the fold stores it.
      refused = attach(through, register(through))
      set(refused, state: "failed", refused_at: now)

      :ok = go_direct(scope, through)
      assert Gateways.delete_blockers(through.gateway) == %{nodes: [], runs: []}
      assert {:ok, _deleted} = Nodes.delete_node(scope, through.gateway)
    end

    test "a run waits to the end of its attach window, that instant included",
         %{scope: scope} do
      through = through(scope)
      {run, _run_key} = register(through)
      :ok = go_direct(scope, through)
      attach_by = reload_run(run).attach_by

      assert %{runs: [%Run{id: id}]} = Gateways.delete_blockers(through.gateway, attach_by)
      assert id == run.id

      after_it = DateTime.add(attach_by, 1, :microsecond)
      assert Gateways.delete_blockers(through.gateway, after_it) == %{nodes: [], runs: []}
    end

    test "a run through another gateway does not hold it", %{scope: scope} do
      through = through(scope)
      other = through(scope)
      attach(other, register(other))
      register(other)
      :ok = go_direct(scope, through)

      assert Gateways.delete_blockers(through.gateway) == %{nodes: [], runs: []}
      assert {:ok, _deleted} = Nodes.delete_node(scope, through.gateway)
      assert reload(other.gateway).deleted_at == nil
    end

    test "nodes and runs are named together, each in its order", %{scope: scope} do
      through = through(scope)
      waiting = register(through) |> elem(0)
      live = attach(through, register(through))

      # Registered in this order, the live run after the waiting one.
      set(live, registered_at: DateTime.add(waiting.registered_at, 1, :second))

      pool =
        pool_fixture(scope,
          name: "a-pool",
          gateway_choice: "named",
          gateway_id: through.gateway.id
        )

      assert {:error, {:gateway_in_use, %{nodes: nodes, runs: runs}}} =
               Nodes.delete_node(scope, through.gateway)

      assert ids(nodes) == Enum.sort_by([pool, through.node], & &1.name) |> ids()
      assert ids(runs) == [waiting.id, live.id]
    end

    test "deleted once its runs end", %{scope: scope} do
      through = through(scope)
      {waiting, _run_key} = register(through)
      live = attach(through, register(through))
      :ok = go_direct(scope, through)

      assert {:error, {:gateway_in_use, %{runs: [_, _]}}} =
               Nodes.delete_node(scope, through.gateway)

      # The live run exits; the waiting one is lost at the end of its attach window.
      set(live, state: "completed", exited_at: DateTime.utc_now())

      assert {:error, {:gateway_in_use, %{runs: [%Run{id: id}]}}} =
               Nodes.delete_node(scope, through.gateway)

      assert id == waiting.id
      assert [%Run{id: ^id}] = Liveness.check(DateTime.add(waiting.attach_by, 1, :second))

      assert {:ok, deleted} = Nodes.delete_node(scope, through.gateway)
      assert deleted.deleted_at
    end
  end

  describe "a purge" do
    test "is never held up by another organisation's node naming its gateway, which stays named",
         %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      gateway = keyed_gateway(other)
      pool = pool_fixture(scope)

      # Only a write past the application names another organisation's gateway.
      Repo.update_all(from(n in Node, where: n.id == ^pool.id),
        set: [gateway_choice: :named, gateway_id: gateway.id]
      )

      assert {:ok, :purged} = Apiary.Deletion.purge_now(other.organisation)
      assert Repo.get(Node, gateway.id) == nil

      # It names a gateway that is gone: not direct, and refused.
      pool = reload(pool)
      assert {pool.gateway_choice, pool.gateway_id} == {:named, nil}
      assert Gateways.resolve(pool) == {:error, :gateway_not_serving}
    end
  end
end

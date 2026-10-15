defmodule Apiary.AdaptersTest do
  # Adapters: nodes of kind `adapter` that live at their organisation, made, renamed,
  # connected and deleted through `Apiary.Adapters`; their access keys, enrolled with a code
  # and verified as any node's; the role their keys act in; a node pool's adapter
  # (`served_by_id`); and the schema that keeps them. It runs where the feature adapters
  # belong to is on; `Apiary.AdaptersWithoutFactoryTest` turns it off.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, AccessKeys, Adapters, Edition, EditionStubs, Nodes, Organisations}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Nodes.{Instance, Node}

  @moduletag needs: :factory

  # The edition holds the organisations a test names suspended, as an edition that
  # suspends an organisation answers for it (`c:Apiary.Edition.check/3`): whatever a scope
  # of one asks is refused, read from the organisation the scope carries.
  defmodule Suspends do
    @moduledoc false
    alias Apiary.Accounts.Scope
    alias Apiary.Organisations.Organisation

    def put(ids), do: Process.put(:suspended_organisations, ids)

    def check(%Scope{organisation: %Organisation{id: id}} = scope, action, subject) do
      if id in (Process.get(:suspended_organisations) || []),
        do: {:error, :forbidden},
        else: Apiary.Edition.module().check(scope, action, subject)
    end

    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  # A key enrolled on `adapter`, as a verified request carries it.
  # The constraint the database refused `fun` by.
  defp refused(fun) do
    %Postgrex.Error{postgres: %{constraint: constraint}} = assert_raise(Postgrex.Error, fun)
    constraint
  end

  defp keyed(scope, adapter) do
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, adapter)
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    %{key: verified, pair: pair}
  end

  # A machine's enrolment with `code`, as it posts it, signed under `pair`.
  defp enrol_request(code, pair) do
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "acme-tracker", now)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "acme-tracker",
          "public_key" => pair.encoded,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    request
  end

  defp issued(scope, node, attrs \\ %{}) do
    {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, attrs)
    {row, Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())}
  end

  # A row of `nodes` like `node`'s with `changes`, for the schema's checks.
  defp row(node, changes) do
    Node.__schema__(:fields)
    |> then(&Map.take(node, &1))
    |> Map.merge(%{id: Ecto.UUID.generate(), name: unique_node_name()})
    |> Map.merge(changes)
  end

  defp na_id, do: Apiary.PublicId.generate("na")

  describe "making one" do
    test "lives at its organisation, as kind adapter with an na_ id, and is audited",
         %{scope: scope} do
      assert {:ok, adapter} = Adapters.create_adapter(scope, %{name: "Acme tracker"})

      assert %Node{
               kind: :adapter,
               workspace_id: nil,
               instance_limit: nil,
               gateway_choice: :direct,
               url: nil,
               default_gateway: false
             } = adapter

      assert adapter.organisation_id == scope.organisation.id
      assert adapter.public_id =~ ~r/^na_[0-9a-hjkmnp-tv-z]{16}$/
      assert [%Node{id: id}] = Adapters.list_adapters(scope)
      assert id == adapter.id
      assert Adapters.get_adapter(scope, adapter.public_id).id == adapter.id

      assert %Entry{action: "adapter.create", subject_kind: "node"} =
               Repo.one!(from e in Entry, where: e.subject_id == ^adapter.id)
    end

    test "its name is 1 to 64 characters without control characters, unique among the organisation's adapters in use",
         %{scope: scope} do
      for name <- ["", String.duplicate("a", 65), "acme\ntracker"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Adapters.create_adapter(scope, %{name: name})

        assert errors_on(changeset)[:name], inspect(name)
      end

      assert {:ok, _} = Adapters.create_adapter(scope, %{name: String.duplicate("a", 64)})
      first = adapter_fixture(scope, name: "Acme tracker")

      assert {:error, changeset} = Adapters.create_adapter(scope, %{name: "Acme tracker"})
      assert "has already been taken" in errors_on(changeset).name

      # A gateway of the organisation may have the name, and another organisation's adapter.
      organisation_gateway_fixture(scope, name: "Acme tracker")
      %{scope: other} = sign_up_fixture()
      assert {:ok, _} = Adapters.create_adapter(other, %{name: "Acme tracker"})

      # Deleted, its name is free again.
      {:ok, _} = Adapters.delete_adapter(scope, first)
      assert {:ok, _} = Adapters.create_adapter(scope, %{name: "Acme tracker"})
    end

    test "only an owner or an admin makes one, of their organisation", %{scope: scope} do
      %{scope: member} = member_fixture(scope, :member)
      %{scope: admin} = member_fixture(scope, :admin)

      assert Adapters.create_adapter(member, %{name: "Acme tracker"}) == {:error, :forbidden}
      assert {:ok, _} = Adapters.create_adapter(admin, %{name: "Acme tracker"})
      assert [_one] = Adapters.list_adapters(scope)
    end

    test "never comes from Apiary.Nodes", %{scope: scope} do
      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "adapter", name: "acme"})
      assert "is invalid" in errors_on(changeset).kind
      assert Repo.aggregate(from(n in Node, where: n.kind == :adapter), :count) == 0

      adapter = adapter_fixture(scope)
      assert Nodes.update_node(scope, adapter, %{name: "renamed"}) == {:error, :not_found}
      assert Nodes.delete_node(scope, adapter) == {:error, :not_found}
      assert Nodes.make_default_gateway(scope, adapter) == {:error, :not_found}
      assert Nodes.get_organisation_gateway(scope, adapter.public_id) == nil
      assert Nodes.list_organisation_gateways(scope) == []
      assert Nodes.list_nodes(scope) == []
      assert reload(adapter).name == adapter.name
    end

    test "another organisation's, a deleted one, or a gateway is not found", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      theirs = adapter_fixture(other)
      gateway = organisation_gateway_fixture(scope)

      assert Adapters.get_adapter(scope, theirs.public_id) == nil
      assert Adapters.get_adapter(scope, gateway.public_id) == nil
      assert Adapters.rename_adapter(scope, theirs, %{name: "x"}) == {:error, :not_found}
      assert Adapters.delete_adapter(scope, gateway) == {:error, :not_found}
      assert Adapters.list_adapters(scope) == []
    end
  end

  describe "renaming and connecting one" do
    test "a rename is audited with its before and after; the same name leaves nothing",
         %{scope: scope} do
      adapter = adapter_fixture(scope, name: "Acme tracker")

      assert {:ok, %Node{name: "Acme issues"}} =
               Adapters.rename_adapter(scope, adapter, %{name: "Acme issues"})

      assert {:ok, _} = Adapters.rename_adapter(scope, adapter, %{name: "Acme issues"})

      assert [%Entry{before: %{"name" => "Acme tracker"}, after: %{"name" => "Acme issues"}}] =
               Repo.all(from e in Entry, where: e.action == "adapter.edit")
    end

    test "connect hands back what the issuer made, and keeps none of it", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{scope: member} = member_fixture(scope, :member)

      assert Adapters.connect(member, adapter, fn _ -> {:ok, "pass"} end) == {:error, :forbidden}

      assert {:ok, "pass-123"} =
               Adapters.connect(scope, adapter, fn current ->
                 assert current.id == adapter.id
                 {:ok, "pass-123"}
               end)

      assert Adapters.connect(scope, adapter, fn _ -> {:error, :unavailable} end) ==
               {:error, :unavailable}

      assert [%Entry{details: details}] =
               Repo.all(from e in Entry, where: e.action == "adapter.connect")

      refute inspect(details) =~ "pass-123"
    end
  end

  describe "its keys" do
    test "a code never brings stored secrets, and a key made in a browser is refused",
         %{scope: scope} do
      adapter = adapter_fixture(scope)

      assert {:ok, %EnrolmentCode{allow_secrets: false, workspace_id: nil}, _code} =
               AccessKeys.create_enrolment_code(scope, adapter, %{allow_secrets: true})

      assert AccessKeys.add_access_key(scope, adapter, %{
               label: "acme",
               public_key: ed25519_key_pair().encoded,
               allow_secrets: false
             }) == {:error, :forbidden}

      assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^adapter.id), :count) == 0
    end

    test "its code is an owner's or an admin's of the organisation", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{scope: member} = member_fixture(scope, :member)
      %{scope: stranger} = sign_up_fixture()

      assert AccessKeys.create_enrolment_code(member, adapter, %{}) == {:error, :forbidden}
      assert AccessKeys.create_enrolment_code(stranger, adapter, %{}) == {:error, :not_found}
    end

    test "a machine enrols one with a code: the key is the adapter's, without a workspace or stored secrets",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      {_row, code} = issued(scope, adapter, %{allow_secrets: true})
      pair = ed25519_key_pair()

      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(enrol_request(code, pair))
      assert key.node_id == adapter.id
      assert key.node.kind == :adapter
      assert key.workspace_id == nil
      assert key.allow_secrets == false
      assert key.arrived_by == :code

      assert Enrolment.answer_body(%{
               access_key_id: key.key_id,
               node_id: key.node.public_id,
               node_kind: key.node.kind,
               stored_secrets: key.allow_secrets,
               apiary_public_key: Apiary.SigningKey.apiary_public_key()
             }) =~
               ~s("node_id":"#{adapter.public_id}","node_kind":"adapter","stored_secrets":false,)

      assert {:ok, %AccessKey{node: %Node{kind: :adapter}}} =
               AccessKeys.fetch_for_verification(key.key_id)
    end

    test "its code enrols only while its maker is still an owner or an admin", %{scope: scope} do
      %{scope: admin, membership: membership} = member_fixture(scope, :admin)
      adapter = adapter_fixture(scope)
      {_row, code} = issued(admin, adapter)
      {:ok, _} = Organisations.set_member_level(scope, membership.id, :member)

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :unauthorized}
    end

    test "it holds two keys at most", %{scope: scope} do
      adapter = adapter_fixture(scope)
      enrolled_key_fixture(scope, adapter)
      enrolled_key_fixture(scope, adapter)
      {_row, code} = issued(scope, adapter)

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :key_limit}
    end

    test "its key is refused once revoked, once the adapter is deleted, or while its organisation is out of use",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: revoked} = keyed(scope, adapter)
      {:ok, _} = AccessKeys.revoke_access_key(scope, revoked)
      assert AccessKeys.fetch_for_verification(revoked.key_id) == :error

      # Out of use: no gateway's leave, the key of an adapter is held to its organisation.
      %{key: key} = keyed(scope, adapter)
      gateway = organisation_gateway_fixture(scope)
      %{access_key: gateway_key} = enrolled_key_fixture(scope, gateway)
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id])

      assert AccessKeys.fetch_for_verification(key.key_id) == :error
      refute AccessKeys.active_key?(adapter)
      assert {:ok, _} = AccessKeys.fetch_for_verification(gateway_key.key_id)

      Process.put(:out_of_use, [])
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)

      {:ok, _} = Adapters.delete_adapter(scope, adapter)
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end

    test "a code of an organisation out of use enrols nothing", %{scope: scope} do
      adapter = adapter_fixture(scope)
      {_row, code} = issued(scope, adapter)
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id])

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :unauthorized}
    end
  end

  describe "the scope and role of its key" do
    test "carries the organisation and no workspace, and acts as adapter_key", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)

      assert %Scope{organisation: organisation, workspace: nil, access_key: ^key} =
               key_scope = Scope.for_access_key(key)

      assert organisation.id == scope.organisation.id
      assert Access.role(key_scope) == :adapter_key

      # Its node and organisation are read when the key does not carry them.
      bare = Repo.get!(AccessKey, key.id)

      assert %Scope{organisation: %{id: id}, workspace: nil} =
               bare_scope = Scope.for_access_key(bare)

      assert id == scope.organisation.id
      assert Access.role(bare_scope) == :adapter_key

      # A gateway's key acts as access_key, with no organisation on its scope.
      gateway = organisation_gateway_fixture(scope)
      %{access_key: gateway_key} = enrolled_key_fixture(scope, gateway)
      gateway_scope = Scope.for_access_key(Repo.get!(AccessKey, gateway_key.id))
      assert Access.role(gateway_scope) == :access_key
      assert gateway_scope.organisation == nil
    end

    test "a key whose node is not known acts in no role", %{scope: scope} do
      %{access_key: key} = access_key_fixture(scope)

      assert Access.role(%Scope{access_key: %{key | node: nil}}) == nil
      assert Access.role(%Scope{access_key: %AccessKey{}}) == nil
      assert Access.role(%Scope{access_key: %{key | node: %Node{kind: nil}}}) == nil
      assert Access.role(Scope.for_access_key(%AccessKey{})) == nil

      refute Access.can?(
               %Scope{access_key: %{key | node: nil}},
               :"run.post_events",
               key.workspace
             )
    end

    test "acts on its adapter alone, and on nothing a node's key does", %{scope: scope} do
      adapter = adapter_fixture(scope)
      other = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)
      key_scope = Scope.for_access_key(key)

      for action <- [:"source_item.post", :"work_item.read_changes", :"dispatch.claim"] do
        assert Access.authorize(key_scope, action, adapter) == :ok
        assert Access.authorize(key_scope, action, other) == {:error, :not_found}
        assert Access.authorize(key_scope, action, scope.organisation) == {:error, :not_found}
        assert Adapters.for_key(key_scope, action) == {:ok, reload(adapter)}
      end

      assert Access.authorize(key_scope, :"adapter.edit", adapter) == {:error, :forbidden}

      assert Access.authorize(key_scope, :"run.post_events", scope.workspace) ==
               {:error, :not_found}

      assert Access.authorize(key_scope, :"run_configuration.fetch", scope.workspace) ==
               {:error, :not_found}

      assert Adapters.for_key(key_scope, :"adapter.edit") == {:error, :forbidden}

      # A node's key takes none of the adapter's actions.
      %{access_key: node_key} = access_key_fixture(scope)
      node_scope = Scope.for_access_key(node_key)

      for action <- [:"source_item.post", :"work_item.read_changes", :"dispatch.claim"] do
        assert Access.authorize(node_scope, action, adapter) == {:error, :forbidden}
        assert Adapters.for_key(node_scope, action) == {:error, :not_found}
      end

      # Its adapter deleted, it stands for none.
      {:ok, _} = Adapters.delete_adapter(scope, adapter)
      assert Adapters.for_key(key_scope, :"source_item.post") == {:error, :not_found}
    end

    test "no person's role holds what an adapter's key does" do
      for {role, actions} <- Access.roles(), role != :adapter_key do
        for action <- [:"source_item.post", :"work_item.read_changes", :"dispatch.claim"] do
          refute action in actions, "#{role} holds #{action}"
        end
      end

      assert Access.action(:"work_item.read_changes").roles == [:adapter_key]
    end

    test "a suspended organisation's adapter is refused through Access.check/3, by the organisation its scope carries",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)
      key_scope = Scope.for_access_key(key)
      Edition.put_test_stub(Suspends)

      Suspends.put([])
      assert Access.check(key_scope, :"source_item.post", adapter) == :ok

      Suspends.put([scope.organisation.id])
      assert Access.check(key_scope, :"source_item.post", adapter) == {:error, :forbidden}
      assert Adapters.for_key(key_scope, :"source_item.post") == {:error, :forbidden}
    end

    test "an organisation marked for deletion refuses its adapter's key", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)
      {:ok, _} = Apiary.Deletion.delete_organisation(scope, scope.organisation.slug)

      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end
  end

  describe "deleting one" do
    test "revokes its keys, cancels its codes and serves no pool any more, in one entry",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)
      {code, _plain} = issued(scope, adapter)
      pool = pool_fixture(scope)
      {:ok, pool} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})
      assert pool.served_by_id == adapter.id
      assert [%Node{id: pool_id}] = Adapters.served_pools(scope, adapter)
      assert pool_id == pool.id

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Adapters.delete_adapter(scope, adapter)

      assert Repo.get!(AccessKey, key.id).revoked_at
      assert Repo.get!(EnrolmentCode, code.id).cancelled_at
      assert reload(pool).served_by_id == nil
      assert Adapters.list_adapters(scope) == []
      assert Adapters.delete_adapter(scope, adapter) == {:error, :not_found}

      assert %Entry{details: details} =
               Repo.one!(from e in Entry, where: e.action == "adapter.delete")

      assert details["unserved_pool_ids"] == [pool.public_id]
      assert details["revoked_key_ids"] == [key.key_id]
    end

    test "only an owner or an admin deletes one", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{scope: member} = member_fixture(scope, :member)

      assert Adapters.delete_adapter(member, adapter) == {:error, :forbidden}
      assert reload(adapter).deleted_at == nil
    end
  end

  describe "a pool's adapter" do
    test "a pool names one of its organisation's adapters in use, and clears it", %{scope: scope} do
      adapter = adapter_fixture(scope)
      pool = pool_fixture(scope)

      assert Adapters.serving_choices(scope) |> Enum.map(& &1.id) == [adapter.id]

      assert {:ok, %Node{served_by_id: id}} =
               Nodes.update_node(scope, pool, %{served_by_id: adapter.id})

      assert id == adapter.id

      assert %Entry{before: %{"served_by_id" => nil}, after: %{"served_by_id" => ^id}} =
               Repo.one!(
                 from e in Entry,
                   where: e.action == "node.edit" and e.subject_id == ^pool.id
               )

      assert {:ok, %Node{served_by_id: nil}} =
               Nodes.update_node(scope, pool, %{served_by_id: nil})

      # A new pool may be made served by one.
      assert {:ok, %Node{served_by_id: ^id}} =
               Nodes.create_node(scope, %{kind: "pool", name: "spot", served_by_id: adapter.id})
    end

    test "another organisation's adapter, a deleted one, or a gateway is refused", %{scope: scope} do
      pool = pool_fixture(scope)
      %{scope: other} = sign_up_fixture()
      theirs = adapter_fixture(other)
      deleted = adapter_fixture(scope)
      {:ok, _} = Adapters.delete_adapter(scope, deleted)
      gateway = organisation_gateway_fixture(scope)

      for id <- [theirs.id, deleted.id, gateway.id, pool.id, Ecto.UUID.generate()] do
        assert {:error, changeset} = Nodes.update_node(scope, pool, %{served_by_id: id})
        assert "is invalid" in errors_on(changeset).served_by_id
      end

      assert reload(pool).served_by_id == nil
    end

    test "a node or a gateway has none", %{scope: scope} do
      adapter = adapter_fixture(scope)
      node = node_fixture(scope)
      gateway = gateway_fixture(scope)

      for subject <- [node, gateway] do
        assert {:ok, %Node{served_by_id: nil}} =
                 Nodes.update_node(scope, subject, %{served_by_id: adapter.id})
      end
    end

    test "a member names none", %{scope: scope} do
      adapter = adapter_fixture(scope)
      pool = pool_fixture(scope)
      %{scope: member} = member_fixture(scope, :member)

      assert Nodes.update_node(member, pool, %{served_by_id: adapter.id}) == {:error, :forbidden}
    end
  end

  describe "the schema" do
    test "an adapter lives at its organisation, never at a workspace", %{scope: scope} do
      adapter = adapter_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_place_check/, fn ->
        Repo.insert_all(Node, [
          row(adapter, %{public_id: na_id(), workspace_id: scope.workspace.id})
        ])
      end

      assert_raise Postgrex.Error, ~r/nodes_place_fixed/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
          set: [workspace_id: scope.workspace.id]
        )
      end

      assert {1, _} = Repo.insert_all(Node, [row(adapter, %{public_id: na_id()})])
    end

    test "its kind and its na_ id go together, and its kind is fixed", %{scope: scope} do
      adapter = adapter_fixture(scope)
      gateway = organisation_gateway_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_public_id_check/, fn ->
        Repo.insert_all(Node, [row(adapter, %{public_id: Apiary.PublicId.generate("ng")})])
      end

      assert_raise Postgrex.Error, ~r/nodes_public_id_check/, fn ->
        Repo.insert_all(Node, [row(gateway, %{public_id: na_id()})])
      end

      assert_raise Postgrex.Error, ~r/nodes_kind_fixed/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [kind: "gateway"])
      end
    end

    test "it has no instance limit, no gateway, no address and no default mark", %{scope: scope} do
      adapter = adapter_fixture(scope)
      gateway = organisation_gateway_fixture(scope)
      at = from(n in Node, where: n.id == ^adapter.id)

      for {set, constraint} <- [
            {[instance_limit: 1], "nodes_instance_limit_check"},
            {[gateway_choice: "default"], "nodes_gateway_choice_check"},
            {[gateway_choice: "named", gateway_id: gateway.id], "nodes_gateway_choice_check"},
            {[url: "https://tracker.example.com"], "nodes_url_check"},
            {[default_gateway: true], "nodes_default_gateway_check"},
            {[name: String.duplicate("a", 65)], "nodes_adapter_name_check"}
          ] do
        assert_raise Postgrex.Error, ~r/#{constraint}/, fn -> Repo.update_all(at, set: set) end
      end
    end

    test "its connect address is https, without user information or whitespace, on an adapter alone",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      node = node_fixture(scope)
      at = from(n in Node, where: n.id == ^adapter.id)

      for url <- [
            "https://tracker.example.com",
            "https://tracker.example.com:8443/connect?state=1#top",
            "https://tracker.example.com/a@b"
          ] do
        assert {1, _} = Repo.update_all(at, set: [connect_url: url])
      end

      for url <- [
            "http://tracker.example.com",
            "https://user:secret@tracker.example.com/connect",
            "https://tracker.example.com/a b",
            "https://",
            "https://tracker.example.com/" <> String.duplicate("a", 2048)
          ] do
        assert_raise Postgrex.Error, ~r/nodes_connect_url_check/, fn ->
          Repo.update_all(at, set: [connect_url: url])
        end
      end

      assert_raise Postgrex.Error, ~r/nodes_adapter_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id),
          set: [connect_url: "https://tracker.example.com"]
        )
      end
    end

    test "connect_url_changeset/2 holds the address to the same", %{scope: scope} do
      adapter = adapter_fixture(scope)

      assert Node.connect_url_changeset(adapter, %{connect_url: "https://tracker.example.com/c"}).valid?

      for url <- [
            "http://tracker.example.com",
            "https://user@tracker.example.com",
            "https://tracker.example.com/a b",
            "https://tracker.example.com/" <> String.duplicate("a", 2048)
          ] do
        refute Node.connect_url_changeset(adapter, %{connect_url: url}).valid?, url
      end

      assert {:ok, %Node{connect_url: "https://tracker.example.com/c"}} =
               adapter
               |> Node.connect_url_changeset(%{connect_url: "https://tracker.example.com/c"})
               |> Repo.update()
    end

    test "its intervals are 60 to 86400 seconds, the minimum never above the default, on an adapter alone",
         %{scope: scope} do
      adapter = adapter_fixture(scope)
      pool = pool_fixture(scope)
      at = from(n in Node, where: n.id == ^adapter.id)

      assert {1, _} =
               Repo.update_all(at,
                 set: [
                   sync_interval: 60,
                   sync_default_interval: 3600,
                   sync_minimum_interval: 300,
                   sync_sends_changes: true
                 ]
               )

      assert {1, _} = Repo.update_all(at, set: [sync_interval: nil, sync_minimum_interval: 3600])

      for set <- [
            [sync_interval: 59],
            [sync_interval: 86_401],
            [sync_default_interval: 30],
            [sync_minimum_interval: 86_401],
            [sync_minimum_interval: 7200]
          ] do
        assert_raise Postgrex.Error, ~r/nodes_sync_check/, fn -> Repo.update_all(at, set: set) end
      end

      for set <- [[sync_interval: 600], [sync_sends_changes: false]] do
        assert_raise Postgrex.Error, ~r/nodes_adapter_check/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: set)
        end
      end
    end

    test "only a pool is served, by an adapter in use of its organisation", %{scope: scope} do
      adapter = adapter_fixture(scope)
      pool = pool_fixture(scope)
      node = node_fixture(scope)
      %{scope: other} = sign_up_fixture()
      theirs = adapter_fixture(other)
      gateway = organisation_gateway_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_served_by_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [served_by_id: adapter.id])
      end

      for id <- [theirs.id, gateway.id, pool.id] do
        assert_raise Postgrex.Error, ~r/nodes_served_by_is_an_adapter/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: [served_by_id: id])
        end
      end

      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert_raise Postgrex.Error, ~r/nodes_served_by_is_an_adapter/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: [served_by_id: adapter.id])
      end
    end

    test "its keys, codes and instances are at its place, and none moves", %{scope: scope} do
      adapter = adapter_fixture(scope)
      %{key: key} = keyed(scope, adapter)
      code = Repo.get_by!(EnrolmentCode, used_by_key_id: key.key_id)
      now = DateTime.utc_now()

      instance =
        Repo.insert!(%Instance{
          organisation_id: adapter.organisation_id,
          workspace_id: nil,
          node_id: adapter.id,
          access_key_id: key.id,
          instance_id: "i_tracker-1",
          first_seen_at: now,
          last_seen_at: now
        })

      # Moved into a workspace, each names the adapter at a place it is not.
      for {schema, id, constraint} <- [
            {AccessKey, key.id, "access_keys_node_id_fkey"},
            {EnrolmentCode, code.id, "access_key_enrolment_codes_node_id_fkey"},
            {Instance, instance.id, "node_instances_node_id_fkey"}
          ] do
        assert refused(fn ->
                 Repo.update_all(from(r in schema, where: r.id == ^id),
                   set: [workspace_id: scope.workspace.id]
                 )
               end) == constraint
      end

      # The other way: a key of a workspace's node, moved out of its workspace.
      %{access_key: node_key} = access_key_fixture(scope)

      assert refused(fn ->
               Repo.update_all(from(k in AccessKey, where: k.id == ^node_key.id),
                 set: [workspace_id: nil]
               )
             end) == "node_place_matches"

      # And the adapter itself does not move into a workspace.
      assert refused(fn ->
               Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
                 set: [workspace_id: scope.workspace.id]
               )
             end) == "nodes_place_fixed"
    end
  end

  test "Apiary.Access's tables name no action of a feature the documentation does not differ by" do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Access)
    undocumented = Apiary.Features.all() -- Apiary.Features.documented()

    hidden = for action <- Access.actions(), Access.feature(action) in undocumented, do: action
    assert :"adapter.create" in hidden

    for action <- hidden do
      refute moduledoc =~ "`#{action}`", "the moduledoc names #{action}"
    end

    refute moduledoc =~ "adapter_key"
    assert moduledoc =~ "`node.create`"
  end
end

defmodule Apiary.AdaptersTest do
  # Adapters: nodes of kind `adapter` that are the instance's, with no organisation and no
  # workspace, made, renamed and deleted by an instance admin through `Apiary.Adapters`, in
  # the trail of the instance's organisation; their access keys, enrolled with a code an
  # instance admin makes, and verified whatever any organisation's state; the role their
  # keys act in; and the schema that keeps them. It runs where the feature adapters belong
  # to is on; `Apiary.AdaptersWithoutFactoryTest` turns it off.
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

  # The actions of an adapter's key at the server contract, which its role alone takes.
  @adapter_key_actions [
    :"adapter.declare",
    :"source_item.post",
    :"work_item.read_changes",
    :"adapter.app_values_set",
    :"adapter.app_values_seal",
    :"adapter.disconnect",
    :"adapter.report_grant",
    :"adapter.end_grant",
    :"adapter.read_grants"
  ]

  # The edition holds the organisations a test names refused, as an edition that refuses
  # an organisation answers for it (`c:Apiary.Edition.check/3`): whatever a scope of one
  # asks is refused, read from the organisation the scope carries.
  defmodule RefusesOrganisations do
    @moduledoc false
    alias Apiary.Accounts.Scope
    alias Apiary.Organisations.Organisation

    def put(ids), do: Process.put(:refused_organisations, ids)

    def check(%Scope{organisation: %Organisation{id: id}} = scope, action, subject) do
      if id in (Process.get(:refused_organisations) || []),
        do: {:error, :forbidden},
        else: Apiary.Edition.module().check(scope, action, subject)
    end

    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, admin: instance_admin_scope()}
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  defp instance_id, do: Edition.instance_organisation_id()

  # `scope` as a sign-in `minutes` ago leaves it (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in(scope, minutes),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), -minutes, :minute))

  # The constraint the database refused `fun` by.
  defp refused(fun) do
    %Postgrex.Error{postgres: %{constraint: constraint}} = assert_raise(Postgrex.Error, fun)
    constraint
  end

  # A key enrolled on `adapter`, as a verified request carries it.
  defp keyed(admin, adapter) do
    %{access_key: key, pair: pair} = enrolled_key_fixture(admin, adapter)
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

  # A key and an outstanding code on each of a node, a pool, a workspace's gateway and an
  # organisation's gateway.
  defp keys_and_codes(scope) do
    for node <- [
          node_fixture(scope),
          pool_fixture(scope),
          gateway_fixture(scope),
          organisation_gateway_fixture(scope)
        ] do
      %{access_key: key} = enrolled_key_fixture(scope, node)
      {code, _plain} = issued(scope, node)
      %{node: node, key: key, code: code}
    end
  end

  # Each key revoked and each code cancelled by `scope`, then a second key and code of each
  # by revoke_node_keys/3, as before.
  defp revoke_and_cancel_each(scope, reloaded, items) do
    for %{node: node, key: key, code: code} <- items do
      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} =
               AccessKeys.revoke_access_key(scope, key)

      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} =
               AccessKeys.cancel_code(scope, code)

      %{access_key: second} = enrolled_key_fixture(scope, node)
      {second_code, _plain} = issued(scope, node)

      assert Repo.transact(fn ->
               AccessKeys.revoke_node_keys(reloaded, node, :node_deleted)
             end) == {:ok, [second.key_id]}

      assert Repo.get!(EnrolmentCode, second_code.id).cancelled_at
    end
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
    test "is the instance's, kind adapter with an na_ id, audited in the instance's organisation",
         %{scope: scope, admin: admin} do
      assert {:ok, adapter} =
               Adapters.create_adapter(admin, %{name: unique_adapter_name("Acme tracker")})

      assert %Node{
               kind: :adapter,
               organisation_id: nil,
               workspace_id: nil,
               instance_limit: nil,
               gateway_choice: :direct,
               url: nil,
               default_gateway: false
             } = adapter

      assert adapter.public_id =~ ~r/^na_[0-9a-hjkmnp-tv-z]{16}$/
      assert [%Node{id: id}] = Adapters.list_adapters(admin)
      assert id == adapter.id
      assert Adapters.get_adapter(admin, adapter.public_id).id == adapter.id

      # An organisation's people read the instance's adapters.
      assert [%Node{id: ^id}] = Adapters.list_adapters(scope)
      %{scope: member} = member_fixture(scope, :member)
      assert Adapters.get_adapter(member, adapter.public_id).id == adapter.id

      assert %Entry{action: "adapter.create", subject_kind: "node", organisation_id: trail} =
               Repo.one!(from e in Entry, where: e.subject_id == ^adapter.id)

      assert trail == instance_id()
    end

    test "its name is 1 to 64 characters without control characters, unique among the instance's adapters in use",
         %{scope: scope, admin: admin} do
      for name <- ["", String.duplicate("a", 65), "acme\ntracker"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Adapters.create_adapter(admin, %{name: name})

        assert errors_on(changeset)[:name], inspect(name)
      end

      for cp <- [0x202E, 0x2066, 0x85] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Adapters.create_adapter(admin, %{name: "acme#{<<cp::utf8>>}tracker"})

        assert errors_on(changeset) == %{name: ["must not contain control characters"]}
      end

      assert {:ok, _} =
               Adapters.create_adapter(admin, %{
                 name: unique_adapter_name("👩#{<<0x200D::utf8>>}💻 tracker")
               })

      assert {:ok, _} =
               Adapters.create_adapter(admin, %{
                 name: String.pad_leading(unique_adapter_name("a"), 64, "a")
               })

      name = unique_adapter_name("Acme tracker")
      first = adapter_fixture(name: name)

      assert {:error, changeset} = Adapters.create_adapter(admin, %{name: name})
      assert "has already been taken" in errors_on(changeset).name

      # A gateway of an organisation may have the name.
      organisation_gateway_fixture(scope, name: name)

      # Deleted, its name is free again.
      {:ok, _} = Adapters.delete_adapter(admin, first)
      assert {:ok, _} = Adapters.create_adapter(admin, %{name: name})
    end

    test "only an instance admin makes one, after a recent sign-in", %{scope: scope, admin: admin} do
      %{scope: member} = member_fixture(scope, :member)
      refute Access.instance_admin?(scope)

      # Counted before and after, not against none: the trail of the instance's organisation
      # may hold what a test outside the sandbox committed and left there.
      created = fn ->
        Repo.aggregate(from(e in Entry, where: e.action == "adapter.create"), :count)
      end

      before = created.()

      assert Adapters.create_adapter(scope, %{name: "Acme tracker"}) == {:error, :forbidden}
      assert Adapters.create_adapter(member, %{name: "Acme tracker"}) == {:error, :forbidden}

      for stale <- [signed_in(admin, 21), put_in(admin.user.authenticated_at, nil)] do
        assert Adapters.create_adapter(stale, %{name: "Acme tracker"}) == {:error, :sudo}
      end

      assert Adapters.list_adapters(admin) == []
      assert created.() == before
    end

    test "never comes from Apiary.Nodes", %{scope: scope} do
      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "adapter", name: "acme"})
      assert "is invalid" in errors_on(changeset).kind
      assert Repo.aggregate(from(n in Node, where: n.kind == :adapter), :count) == 0

      adapter = adapter_fixture()
      assert Nodes.update_node(scope, adapter, %{name: "renamed"}) == {:error, :not_found}
      assert Nodes.delete_node(scope, adapter) == {:error, :not_found}
      assert Nodes.make_default_gateway(scope, adapter) == {:error, :not_found}
      assert Nodes.get_organisation_gateway(scope, adapter.public_id) == nil
      assert Nodes.list_organisation_gateways(scope) == []
      assert Nodes.list_nodes(scope) == []
      assert reload(adapter).name == adapter.name
    end

    test "a deleted one, or a gateway, is not found", %{scope: scope, admin: admin} do
      deleted = adapter_fixture()
      {:ok, _} = Adapters.delete_adapter(admin, deleted)
      gateway = organisation_gateway_fixture(scope)

      assert Adapters.get_adapter(admin, deleted.public_id) == nil
      assert Adapters.get_adapter(admin, gateway.public_id) == nil
      assert Adapters.rename_adapter(admin, gateway, %{name: "x"}) == {:error, :not_found}
      assert Adapters.delete_adapter(admin, gateway) == {:error, :not_found}
      assert Adapters.list_adapters(admin) == []
    end

    test "nobody but an organisation's people and the instance admins reads them",
         %{scope: scope} do
      adapter = adapter_fixture()
      %{user: user} = sign_up_fixture()

      # No organisation on the scope, or one the feature is hidden in.
      assert Adapters.list_adapters(Scope.for_user(user)) == []
      assert Adapters.get_adapter(Scope.for_user(user), adapter.public_id) == nil

      Edition.put_test_stub(EditionStubs.HidesNamed)
      EditionStubs.HidesNamed.put([:factory])
      hidden = Access.reload(scope)

      assert Adapters.list_adapters(hidden) == []
      assert Adapters.get_adapter(hidden, adapter.public_id) == nil
    end
  end

  describe "renaming and connecting one" do
    test "an instance admin renames one, audited with its before and after; the same name leaves nothing",
         %{scope: scope, admin: admin} do
      name = unique_adapter_name("Acme tracker")
      renamed = unique_adapter_name("Acme issues")
      adapter = adapter_fixture(name: name)

      assert Adapters.rename_adapter(scope, adapter, %{name: renamed}) ==
               {:error, :forbidden}

      assert {:ok, %Node{name: ^renamed}} =
               Adapters.rename_adapter(admin, adapter, %{name: renamed})

      assert {:ok, _} = Adapters.rename_adapter(admin, adapter, %{name: renamed})

      assert [
               %Entry{
                 organisation_id: trail,
                 before: %{"name" => ^name},
                 after: %{"name" => ^renamed}
               }
             ] = Repo.all(from e in Entry, where: e.action == "adapter.edit")

      assert trail == instance_id()
    end

    test "an owner or an admin connects one to their organisation, which holds the entry, and keeps none of the pass",
         %{scope: scope} do
      %{adapter: adapter} = connectable_adapter_fixture()
      %{scope: member} = member_fixture(scope, :member)

      assert Adapters.connect(member, adapter) == {:error, :forbidden}

      assert {:ok, "https://tracker.example.com/connect?state=" <> pass, {connection_id, _nonce}} =
               Adapters.connect(scope, adapter)

      assert [%Entry{organisation_id: trail, subject_kind: "organisation", details: details}] =
               Repo.all(from e in Entry, where: e.action == "adapter.connect")

      assert trail == scope.organisation.id
      assert details["public_id"] == adapter.public_id
      assert details["connection_id"] == connection_id
      refute inspect(details) =~ pass
    end
  end

  describe "its keys" do
    test "a code never brings stored secrets, and a key made in a browser is refused",
         %{admin: admin} do
      adapter = adapter_fixture()

      assert {:ok, %EnrolmentCode{allow_secrets: false, organisation_id: nil, workspace_id: nil},
              _code} = AccessKeys.create_enrolment_code(admin, adapter, %{allow_secrets: true})

      assert {:error, _refused} =
               AccessKeys.add_access_key(admin, adapter, %{
                 label: "acme",
                 public_key: ed25519_key_pair().encoded,
                 allow_secrets: false
               })

      assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^adapter.id), :count) == 0

      assert [%Entry{organisation_id: trail}] =
               Repo.all(from e in Entry, where: e.action == "access_key.create_code")

      assert trail == instance_id()
    end

    test "its code is an instance admin's, after a recent sign-in", %{scope: scope, admin: admin} do
      adapter = adapter_fixture()
      %{scope: member} = member_fixture(scope, :member)

      assert AccessKeys.create_enrolment_code(scope, adapter, %{}) == {:error, :forbidden}
      assert AccessKeys.create_enrolment_code(member, adapter, %{}) == {:error, :forbidden}

      assert AccessKeys.create_enrolment_code(signed_in(admin, 21), adapter, %{}) ==
               {:error, :sudo}

      assert Repo.aggregate(from(c in EnrolmentCode, where: c.node_id == ^adapter.id), :count) ==
               0

      # Its codes and keys are read by an instance admin alone.
      {_row, _code} = issued(admin, adapter)
      assert [_one] = AccessKeys.list_enrolment_codes(admin, adapter)
      assert AccessKeys.list_enrolment_codes(scope, adapter) == []
      assert AccessKeys.list_for_node(scope, adapter) == []
    end

    test "a machine enrols one with a code: the key is the adapter's, without an organisation, a workspace or stored secrets",
         %{admin: admin} do
      adapter = adapter_fixture()
      {_row, code} = issued(admin, adapter, %{allow_secrets: true})
      pair = ed25519_key_pair()

      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(enrol_request(code, pair))
      assert key.node_id == adapter.id
      assert key.node.kind == :adapter
      assert key.organisation_id == nil
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

      assert [%AccessKey{id: id}] = AccessKeys.list_for_node(admin, adapter)
      assert id == key.id

      assert %Entry{organisation_id: trail, actor_kind: :access_key} =
               Repo.one!(from e in Entry, where: e.action == "access_key.add")

      assert trail == instance_id()
    end

    test "its code enrols only while its maker is still an instance admin", %{scope: scope} do
      %{user: user} = sign_up_fixture()
      {:ok, %{granted?: true}} = Organisations.grant_instance_admin(user)
      maker = signed_in(Organisations.load_scope(Scope.for_user(user)), 0)
      adapter = adapter_fixture()
      {_row, code} = issued(maker, adapter)
      {:ok, _} = Organisations.revoke_instance_admin(user)

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :unauthorized}

      # A code of an adapter whose maker is an owner of an organisation, not an instance
      # admin, approves nothing either.
      {row, code} = issued(instance_admin_scope(), adapter)

      row
      |> Ecto.Changeset.change(created_by_id: scope.user.id)
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :unauthorized}
      assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^adapter.id), :count) == 0
    end

    test "it holds two keys at most", %{admin: admin} do
      adapter = adapter_fixture()
      enrolled_key_fixture(admin, adapter)
      enrolled_key_fixture(admin, adapter)
      {_row, code} = issued(admin, adapter)

      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) == {:error, :key_limit}
    end

    test "its key is verified whatever any organisation's state, and refused once revoked or its adapter deleted",
         %{scope: scope, admin: admin} do
      adapter = adapter_fixture()
      %{key: revoked} = keyed(admin, adapter)
      assert AccessKeys.revoke_access_key(scope, revoked) == {:error, :forbidden}
      {:ok, _} = AccessKeys.revoke_access_key(admin, revoked)
      assert AccessKeys.fetch_for_verification(revoked.key_id) == :error

      assert %Entry{organisation_id: trail} =
               Repo.one!(from e in Entry, where: e.action == "access_key.revoke")

      assert trail == instance_id()

      # Every organisation out of use, the instance's among them: a node's key is refused,
      # the adapter's verified, and a code of the adapter still enrols.
      %{key: key} = keyed(admin, adapter)
      %{access_key: node_key} = access_key_fixture(scope)
      {_row, code} = issued(admin, adapter)
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id, instance_id()])

      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)
      assert AccessKeys.active_key?(adapter)
      assert AccessKeys.fetch_for_verification(node_key.key_id) == :error
      assert {:ok, _} = AccessKeys.enrol(enrol_request(code, ed25519_key_pair()))

      # An organisation marked for deletion holds it no more.
      Process.put(:out_of_use, [])
      {:ok, _} = Apiary.Deletion.delete_organisation(scope, scope.organisation.slug)
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)

      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
    end

    test "an instance admin revokes its key and cancels its code, one by one or all at once",
         %{admin: admin} do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      {code, _plain} = issued(admin, adapter)

      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} =
               AccessKeys.revoke_access_key(admin, key)

      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} =
               AccessKeys.cancel_code(admin, code)

      %{key: second} = keyed(admin, adapter)
      {second_code, _plain} = issued(admin, adapter)

      assert {:ok, [key_id]} =
               Repo.transact(fn ->
                 AccessKeys.revoke_node_keys(Access.reload(admin), adapter, :node_deleted)
               end)

      assert key_id == second.key_id
      assert Repo.get!(AccessKey, second.id).revoked_at
      assert Repo.get!(EnrolmentCode, second_code.id).cancelled_at
    end

    test "an instance admin follows its keys and codes on the instance's topic, from a scope in another organisation",
         %{scope: scope, admin: admin} do
      adapter = adapter_fixture()
      other = adapter_fixture()
      {_row, code} = issued(admin, adapter)
      {other_code, _plain} = issued(admin, other)

      # The admin's scope in another organisation, as an Instance page's carries the one
      # they opened last.
      elsewhere = Scope.in_organisation(admin, scope.organisation)

      assert AccessKeys.subscribe(elsewhere, adapter) == :ok

      assert AccessKeys.topic(AccessKeys.place_id(adapter), adapter.id) ==
               "access_keys:instance:#{adapter.id}"

      assert {:ok, key} = AccessKeys.enrol(enrol_request(code, ed25519_key_pair()))
      assert_receive {:key_enrolled, %{key_id: key_id, node_id: node_id}}
      assert {key_id, node_id} == {key.key_id, adapter.id}

      {code_row, _plain} = issued(admin, adapter)
      assert {:ok, _} = AccessKeys.cancel_code(admin, code_row)
      assert_receive {:code_cancelled, %{code_id: code_id, node_id: ^node_id}}
      assert code_id == code_row.id

      # Another adapter's code says nothing here.
      assert {:ok, _} = AccessKeys.cancel_code(admin, other_code)
      refute_receive {:code_cancelled, %{node_id: _}}, 100
    end

    test "anyone else is refused its topic, as reading its keys", %{scope: scope} do
      adapter = adapter_fixture()
      %{scope: member} = member_fixture(scope, :member)

      for asker <- [scope, member] do
        assert AccessKeys.subscribe(asker, adapter) == {:error, :forbidden}
      end
    end
  end

  describe "what its pages call" do
    test "an instance admin makes one with its first code, in one transaction, after a recent sign-in",
         %{scope: scope, admin: admin} do
      name = unique_adapter_name("Acme tracker")

      assert {:ok, %Node{kind: :adapter} = adapter, %EnrolmentCode{} = row, code} =
               Adapters.create_adapter_with_code(admin, %{name: name})

      assert row.node_id == adapter.id
      assert row.allow_secrets == false
      assert EnrolmentCode.hash(code) == row.code_sha256
      assert [%EnrolmentCode{id: id}] = Adapters.list_codes(admin, adapter)
      assert id == row.id

      # Refused, or a name taken: neither the adapter nor a code is made.
      assert Adapters.create_adapter_with_code(scope, %{name: "Other"}) == {:error, :forbidden}

      assert Adapters.create_adapter_with_code(signed_in(admin, 21), %{name: "Other"}) ==
               {:error, :sudo}

      assert {:error, %Ecto.Changeset{}} =
               Adapters.create_adapter_with_code(admin, %{name: name})

      assert Repo.aggregate(from(n in Node, where: n.kind == :adapter), :count) == 1
      assert Repo.aggregate(EnrolmentCode, :count) == 1
    end

    test "an instance admin reads its keys and codes, makes a code, revokes a key and cancels a code; anyone else reads none",
         %{scope: scope, admin: admin} do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)

      assert {:ok, %EnrolmentCode{allow_secrets: false} = row, _code} =
               Adapters.create_code(admin, adapter)

      assert [%AccessKey{id: key_row_id}] = Adapters.list_keys(admin, adapter)
      assert key_row_id == key.id
      assert [%EnrolmentCode{id: row_id}] = Adapters.list_codes(admin, adapter)
      assert row_id == row.id
      assert Adapters.list_keys(scope, adapter) == []
      assert Adapters.list_codes(scope, adapter) == []
      assert Adapters.create_code(scope, adapter) == {:error, :forbidden}
      assert Adapters.subscribe_keys(scope, adapter) == {:error, :forbidden}

      assert Adapters.subscribe_keys(admin, adapter) == :ok
      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} = Adapters.cancel_code(admin, row)
      assert_receive {:code_cancelled, %{code_id: ^row_id}}
      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} = Adapters.revoke_key(admin, key)
    end
  end

  describe "the scope and role of its key" do
    test "carries no organisation and no workspace, and acts as adapter_key", %{
      scope: scope,
      admin: admin
    } do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)

      assert %Scope{organisation: nil, workspace: nil, access_key: ^key} =
               key_scope = Scope.for_access_key(key)

      assert Access.role(key_scope) == :adapter_key
      assert Scope.key_place(key_scope) == nil

      # Its node is read when the key does not carry it.
      bare = Repo.get!(AccessKey, key.id)
      assert %Scope{organisation: nil, workspace: nil} = bare_scope = Scope.for_access_key(bare)
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

    test "acts on its adapter alone, and on nothing a node's key does", %{
      scope: scope,
      admin: admin
    } do
      adapter = adapter_fixture()
      other = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      key_scope = Scope.for_access_key(key)

      for action <- @adapter_key_actions do
        assert Access.authorize(key_scope, action, adapter) == :ok
        assert Access.authorize(key_scope, action, other) == {:error, :not_found}
        assert Access.authorize(key_scope, action, scope.organisation) == {:error, :not_found}

        assert Access.authorize(key_scope, action, %Apiary.Organisations.Organisation{}) ==
                 {:error, :not_found}

        assert Access.authorize(key_scope, action, key) == {:error, :not_found}
        assert Access.authorize(key_scope, action, nil) == {:error, :not_found}
        assert Adapters.for_key(key_scope, action) == {:ok, reload(adapter)}
      end

      assert Access.authorize(key_scope, :"adapter.edit", adapter) == {:error, :forbidden}

      assert Access.authorize(key_scope, :"run.post_events", scope.workspace) ==
               {:error, :not_found}

      assert Access.authorize(key_scope, :"run.post_events", Scope.key_place(key_scope)) ==
               {:error, :not_found}

      assert Access.authorize(key_scope, :"run_configuration.fetch", scope.workspace) ==
               {:error, :not_found}

      assert Adapters.for_key(key_scope, :"adapter.edit") == {:error, :forbidden}

      # A node's key, a person, and the instance take none of the adapter's actions: the
      # adapter is no place of theirs.
      %{access_key: node_key} = access_key_fixture(scope)

      for asker <- [
            Scope.for_access_key(node_key),
            scope,
            Scope.for_instance(scope.organisation)
          ],
          action <- @adapter_key_actions do
        assert Access.authorize(asker, action, adapter) == {:error, :not_found}
        assert Adapters.for_key(asker, action) == {:error, :not_found}
      end

      # Its adapter deleted, it stands for none.
      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert Adapters.for_key(key_scope, :"source_item.post") == {:error, :not_found}
    end

    test "no person's role holds what an adapter's key does" do
      for {role, actions} <- Access.roles(), role != :adapter_key do
        for action <- @adapter_key_actions do
          refute action in actions, "#{role} holds #{action}"
        end
      end

      for action <- @adapter_key_actions do
        assert Access.action(action).roles == [:adapter_key]
      end

      # The adapter's key holds these actions and no other: no claim of dispatched work.
      assert Access.roles().adapter_key == @adapter_key_actions
      refute :"dispatch.claim" in Access.roles().adapter_key

      for action <- [
            :"adapter.create",
            :"adapter.edit",
            :"adapter.set_interval",
            :"adapter.delete",
            :"adapter.setup"
          ] do
        assert Access.action(action).roles == []
      end
    end

    test "an edition's refusal for an organisation does not refuse it: its scope carries none", %{
      scope: scope,
      admin: admin
    } do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      key_scope = Scope.for_access_key(key)
      Edition.put_test_stub(RefusesOrganisations)
      RefusesOrganisations.put([scope.organisation.id, instance_id()])

      assert Access.check(key_scope, :"source_item.post", adapter) == :ok
      assert Adapters.for_key(key_scope, :"source_item.post") == {:ok, reload(adapter)}
    end
  end

  describe "deleting one" do
    test "revokes its keys and cancels its codes, in one entry of the instance's organisation",
         %{admin: admin} do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      {code, _plain} = issued(admin, adapter)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Adapters.delete_adapter(admin, adapter)

      assert Repo.get!(AccessKey, key.id).revoked_at
      assert Repo.get!(EnrolmentCode, code.id).cancelled_at
      assert Adapters.list_adapters(admin) == []
      assert Adapters.delete_adapter(admin, adapter) == {:error, :not_found}

      assert %Entry{organisation_id: trail, details: details} =
               Repo.one!(from e in Entry, where: e.action == "adapter.delete")

      assert trail == instance_id()
      assert details["ended_connection_ids"] == []
      assert details["revoked_key_ids"] == [key.key_id]

      assert [%Entry{organisation_id: ^trail}] =
               Repo.all(from e in Entry, where: e.action == "access_key.revoke")
    end

    test "only an instance admin deletes one", %{scope: scope} do
      adapter = adapter_fixture()
      %{scope: member} = member_fixture(scope, :member)

      assert Adapters.delete_adapter(scope, adapter) == {:error, :forbidden}
      assert Adapters.delete_adapter(member, adapter) == {:error, :forbidden}
      assert AccessKeys.revoke_node_keys(scope, adapter, :node_deleted) == {:error, :forbidden}
      assert reload(adapter).deleted_at == nil
    end
  end

  describe "installed with Qory Apiary" do
    # The installer's pass and the listing are `Apiary.Adapters.InstalledTest`'s; here, what
    # holds whatever the setting lists: in this suite it lists none.

    test "install/2 makes the adapter once, by the instance, with its entry, and finds it again" do
      name = "tracker-#{System.unique_integer([:positive])}"
      scope = instance_scope()

      assert {:ok, %Node{installed_as: ^name, name: ^name, created_by_id: nil} = adapter} =
               Adapters.install(scope, name)

      assert {:ok, %Node{id: id}} = Adapters.install(scope, name)
      assert id == adapter.id
      assert Adapters.installed?(adapter)
      refute Adapters.listed?(adapter)

      assert [%Entry{actor_kind: :instance, actor_id: nil, organisation_id: trail}] =
               Repo.all(
                 from e in Entry,
                   where: e.subject_id == ^adapter.id and e.action == "adapter.install"
               )

      assert trail == instance_id()
    end

    test "the name it is installed as is never cast, and a person's code for it is refused",
         %{admin: admin} do
      adapter = installed_adapter_fixture()
      name = adapter.installed_as

      assert {:ok, renamed} =
               Adapters.rename_adapter(admin, adapter, %{
                 name: unique_adapter_name("Renamed"),
                 installed_as: "other"
               })

      assert renamed.installed_as == name
      refute Adapters.installed?(adapter_fixture())

      assert {:error, :installed} = AccessKeys.create_enrolment_code(admin, adapter, %{})
      assert {:error, :installed} = Adapters.create_code(admin, adapter)
      assert Repo.all(from c in EnrolmentCode, where: c.node_id == ^adapter.id) == []
    end

    test "not listed, its code that names no maker enrols nothing", %{admin: admin} do
      adapter = installed_adapter_fixture()
      code = EnrolmentCode.generate(:adapter)

      %EnrolmentCode{
        id: Ecto.UUID.generate(),
        node_id: adapter.id,
        code_sha256: EnrolmentCode.hash(code),
        expires_at: DateTime.add(DateTime.utc_now(), 10, :minute)
      }
      |> Ecto.Changeset.change()
      |> EnrolmentCode.put_integrity()
      |> Repo.insert!()

      issued = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())
      pair = ed25519_key_pair()
      assert {:error, :unauthorized} = AccessKeys.enrol(enrol_request(issued, pair))

      # Not listed, it is removed as any adapter is.
      assert {:ok, %Node{deleted_at: %DateTime{}}} = Adapters.delete_adapter(admin, adapter)
    end

    test "the schema keeps the name to adapters, well formed, one in use each" do
      adapter = installed_adapter_fixture()
      %{scope: scope} = sign_up_fixture()
      node = node_fixture(scope)

      assert refused(fn ->
               Repo.update_all(from(n in Node, where: n.id == ^node.id),
                 set: [installed_as: "tracker"]
               )
             end) == "nodes_installed_as_check"

      for bad <- ["Tracker", "-tracker", "tracker_one", String.duplicate("a", 33)] do
        assert refused(fn ->
                 Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
                   set: [installed_as: bad]
                 )
               end) == "nodes_installed_as_check"
      end

      assert refused(fn ->
               Repo.insert_all(Node, [row(adapter, %{public_id: na_id()})])
             end) == "nodes_installed_as_index"

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
          set: [deleted_at: DateTime.utc_now()]
        )

      assert {1, _} = Repo.insert_all(Node, [row(adapter, %{public_id: na_id()})])
    end

    test "only the instance installs, in the instance's organisation", %{admin: admin} do
      %{scope: other} = sign_up_fixture()
      assert {:error, :forbidden} = Adapters.install(admin, "tracker")

      assert {:error, :forbidden} =
               Adapters.install(Scope.for_instance(other.organisation), "tracker")

      assert {:error, :invalid} = Adapters.install(instance_scope(), "Tracker")
    end
  end

  describe "the apply items of its work credential, at each start" do
    # A declaration as `Apiary.Adapters.Wire.declaration/1` reads one, with `document` as
    # its description.
    defp declare_with(adapter_key, document) do
      {:ok, description} = document |> Jason.encode!() |> Apiary.Integrations.Description.parse()

      Adapters.declare(Scope.for_access_key(adapter_key), %{
        time: ~U[2026-10-25 12:00:00Z],
        connect_url: "https://tracker-adapter.acme.example/connect",
        default_interval: 3600,
        minimum_interval: 900,
        sends_changes: true,
        description: description
      })
    end

    setup %{admin: admin} do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      %{adapter: adapter, key: key}
    end

    test "are kept with the description's exact egress_hosts, and a start without them clears them",
         %{adapter: adapter, key: key} do
      document =
        "example-source-apply-bearer.json"
        |> Apiary.DescriptionFixtures.contract_description()
        |> Map.put("egress_hosts", ["api.example.com", "cdn.example.com"])

      assert {:ok, _declared} = declare_with(key, document)

      assert %Node{
               source_apply: [
                 %{
                   "hosts" => ["api.example.com"],
                   "scheme" => "bearer",
                   "paths" => ["/projects/{target.path}", "/projects/{target.path}/*", "/user"]
                 }
               ],
               egress_hosts: ["api.example.com", "cdn.example.com"]
             } = reload(adapter)

      assert {:ok, _declared} =
               declare_with(key, Apiary.DescriptionFixtures.contract_description())

      assert %Node{source_apply: nil, egress_hosts: nil} = reload(adapter)
    end

    test "the database keeps them only on an adapter, 1 to 16 objects", %{
      adapter: adapter,
      scope: scope
    } do
      node = node_fixture(scope)
      item = %{"hosts" => ["api.example.com"], "scheme" => "bearer"}

      for {id, changes} <- [
            {node.id, [source_apply: [item]]},
            {node.id, [egress_hosts: ["api.example.com"]]},
            {adapter.id, [source_apply: []]},
            {adapter.id, [source_apply: List.duplicate(item, 17)]},
            {adapter.id, [egress_hosts: []]},
            {adapter.id, [egress_hosts: [nil]]}
          ] do
        assert refused(fn ->
                 Repo.update_all(from(n in Node, where: n.id == ^id), set: changes)
               end) == "nodes_source_apply_check",
               inspect(changes)
      end

      assert {:error, %Postgrex.Error{postgres: %{constraint: "nodes_source_apply_check"}}} =
               Repo.query("UPDATE nodes SET source_apply = '[1]'::jsonb WHERE id = $1", [
                 Ecto.UUID.dump!(adapter.id)
               ])

      assert {1, _rows} =
               Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
                 set: [source_apply: List.duplicate(item, 16), egress_hosts: ["api.example.com"]]
               )
    end
  end

  describe "the schema" do
    test "a node has no organisation only when it is an adapter, or the instance's pool or gateway, which have no workspace either",
         %{scope: scope} do
      adapter = adapter_fixture()
      gateway = organisation_gateway_fixture(scope)
      node = node_fixture(scope)

      for changes <- [
            %{public_id: na_id(), organisation_id: scope.organisation.id},
            %{
              public_id: na_id(),
              organisation_id: scope.organisation.id,
              workspace_id: scope.workspace.id
            }
          ] do
        assert refused(fn -> Repo.insert_all(Node, [row(adapter, changes)]) end) ==
                 "nodes_place_check"
      end

      assert refused(fn ->
               Repo.insert_all(Node, [
                 row(node, %{
                   public_id: Apiary.PublicId.generate("nd"),
                   organisation_id: nil,
                   workspace_id: nil
                 })
               ])
             end) == "nodes_place_check"

      # A gateway, or a pool, with no organisation is the instance's: this module is async,
      # and the instance has one of each, so `Apiary.Nodes.InstanceNodeMigrationTest`, which
      # is not, makes them. Neither has a workspace without an organisation.
      assert refused(fn ->
               Repo.insert_all(Node, [
                 row(gateway, %{
                   public_id: Apiary.PublicId.generate("ng"),
                   organisation_id: nil,
                   workspace_id: scope.workspace.id
                 })
               ])
             end) == "nodes_place_check"

      # None moves: an adapter takes no organisation, and a gateway keeps its own.
      assert refused(fn ->
               Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
                 set: [organisation_id: scope.organisation.id]
               )
             end) == "nodes_place_fixed"

      assert refused(fn ->
               Repo.update_all(from(n in Node, where: n.id == ^gateway.id),
                 set: [organisation_id: nil]
               )
             end) == "nodes_place_fixed"

      assert refused(fn ->
               Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
                 set: [workspace_id: scope.workspace.id]
               )
             end) == "nodes_place_fixed"

      assert {1, _} = Repo.insert_all(Node, [row(adapter, %{public_id: na_id()})])
    end

    test "its name is unique among the instance's adapters in use", %{admin: admin} do
      name = unique_adapter_name("Acme tracker")
      adapter = adapter_fixture(name: name)

      assert refused(fn ->
               Repo.insert_all(Node, [row(adapter, %{public_id: na_id(), name: name})])
             end) == "nodes_adapter_name_index"

      {:ok, _} = Adapters.delete_adapter(admin, adapter)

      assert {1, _} =
               Repo.insert_all(Node, [row(adapter, %{public_id: na_id(), name: name})])
    end

    test "its kind and its na_ id go together, and its kind is fixed", %{scope: scope} do
      adapter = adapter_fixture()
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
      adapter = adapter_fixture()
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
      adapter = adapter_fixture()
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

    test "connect_url_changeset/2 holds the address to the same" do
      adapter = adapter_fixture()

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
      adapter = adapter_fixture()
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

    test "its keys and codes have no organisation and no workspace, and none moves", %{
      scope: scope,
      admin: admin
    } do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      code = Repo.get_by!(EnrolmentCode, used_by_key_id: key.key_id)

      # Into a workspace, or an organisation: each names the adapter at a place it is not.
      for {schema, id, check} <- [
            {AccessKey, key.id, "access_keys_place_check"},
            {EnrolmentCode, code.id, "access_key_enrolment_codes_place_check"}
          ] do
        assert refused(fn ->
                 Repo.update_all(from(r in schema, where: r.id == ^id),
                   set: [workspace_id: scope.workspace.id]
                 )
               end) == check

        assert refused(fn ->
                 Repo.update_all(from(r in schema, where: r.id == ^id),
                   set: [organisation_id: scope.organisation.id]
                 )
               end) == "node_place_matches"
      end

      # An adapter has no instances of an organisation. A row without one is the shape of the
      # instance's pool's and gateway's rows, which the schema accepts for any node with no
      # organisation; only those two write one (`Apiary.Nodes.seen/3`).
      now = DateTime.utc_now()

      instance = fn organisation_id ->
        Repo.insert_all(Instance, [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: organisation_id,
            workspace_id: nil,
            node_id: adapter.id,
            access_key_id: key.id,
            node_instance_id: "i_tracker-1",
            first_seen_at: now,
            last_seen_at: now
          }
        ])
      end

      assert refused(fn -> instance.(scope.organisation.id) end) == "node_place_matches"

      # The other way: a key of a workspace's node or of an organisation's gateway, out of
      # its organisation.
      %{access_key: node_key} = access_key_fixture(scope)
      gateway = organisation_gateway_fixture(scope)
      %{access_key: gateway_key} = enrolled_key_fixture(scope, gateway)

      assert refused(fn ->
               Repo.update_all(from(k in AccessKey, where: k.id == ^node_key.id),
                 set: [workspace_id: nil]
               )
             end) == "node_place_matches"

      assert refused(fn ->
               Repo.update_all(from(k in AccessKey, where: k.id == ^node_key.id),
                 set: [organisation_id: nil]
               )
             end) == "access_keys_place_check"

      assert refused(fn ->
               Repo.update_all(from(k in AccessKey, where: k.id == ^gateway_key.id),
                 set: [organisation_id: nil]
               )
             end) == "node_place_matches"

      # The adapter's row, and its code's, stay while a key names them.
      assert refused(fn -> Repo.delete_all(from(n in Node, where: n.id == ^adapter.id)) end) =~
               ~r/^(access_keys_node_fkey|access_key_enrolment_codes_node_fkey)$/

      assert refused(fn ->
               Repo.delete_all(from(c in EnrolmentCode, where: c.id == ^code.id))
             end) == "access_keys_enrolment_code_fkey"
    end
  end

  describe "where the person is not shown the feature" do
    # Made while the person is shown it; then the edition hides it from them, an instance
    # admin among them.
    setup %{scope: scope, admin: admin} do
      adapter = adapter_fixture()
      %{key: key} = keyed(admin, adapter)
      {code, _plain} = issued(admin, adapter)
      others = keys_and_codes(scope)

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Access.reload(scope)
      refute Apiary.Features.visible?(hidden, :factory)
      refute Apiary.Features.visible?(Access.reload(admin), :factory)

      %{adapter: adapter, key: key, code: code, others: others, hidden: hidden}
    end

    # An adapter is the instance's: an instance admin reaches it where the instance has the
    # feature, whatever the organisation their scope carries shows them.
    test "an instance admin reads and changes an adapter, its key and its code all the same", %{
      admin: admin,
      adapter: adapter,
      key: key,
      code: code
    } do
      hidden_admin = Access.reload(admin)
      refute Apiary.Features.visible?(hidden_admin, :factory)
      assert Apiary.Features.on?(:factory)

      assert Adapters.authorize_instance(admin) == :ok
      assert Adapters.authorize_instance(admin, sudo: true) == :ok

      # The reads: the adapter, and its keys and codes at the instance (`read_place/2`).
      assert adapter.id in Enum.map(Adapters.list_adapters(hidden_admin), & &1.id)
      assert %Node{id: id} = Adapters.get_adapter(hidden_admin, adapter.public_id)
      assert id == adapter.id
      assert key.id in Enum.map(AccessKeys.list_for_node(hidden_admin, adapter), & &1.id)
      assert code.id in Enum.map(AccessKeys.list_enrolment_codes(hidden_admin, adapter), & &1.id)

      # The topic of its keys, which hears a code cancelled.
      assert AccessKeys.subscribe(hidden_admin, adapter) == :ok
      code_id = code.id

      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} =
               AccessKeys.cancel_code(admin, code)

      assert_receive {:code_cancelled, %{code_id: ^code_id}}

      # The changes.
      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} = AccessKeys.revoke_access_key(admin, key)

      assert {:ok, %EnrolmentCode{}, _code} =
               AccessKeys.create_enrolment_code(admin, adapter, %{})

      renamed = unique_adapter_name("Acme renamed")

      assert {:ok, %Node{name: ^renamed}} =
               Adapters.rename_adapter(admin, adapter, %{name: renamed})

      assert {:ok, %Node{kind: :adapter}} =
               Adapters.create_adapter(admin, %{name: unique_adapter_name("Acme hidden")})

      assert {:ok, %Node{}} = Adapters.delete_adapter(admin, adapter)
      assert %Node{deleted_at: %DateTime{}} = reload(adapter)
    end

    test "anyone else is refused, and nothing changes", %{
      scope: scope,
      adapter: adapter,
      key: key,
      code: code
    } do
      refute Access.instance_admin?(scope)

      # The entries of what is refused here, the adapter's creation among them.
      entries = fn ->
        Repo.all(
          from e in Entry,
            where:
              e.action in [
                "access_key.revoke",
                "access_key.cancel_code",
                "access_key.create_code",
                "adapter.create",
                "adapter.edit",
                "adapter.delete"
              ],
            select: e.id
        )
      end

      before = entries.()

      assert Adapters.authorize_instance(scope) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(scope, key) == {:error, :forbidden}
      assert AccessKeys.cancel_code(scope, code) == {:error, :forbidden}
      assert AccessKeys.create_enrolment_code(scope, adapter, %{}) == {:error, :forbidden}

      assert Repo.transact(fn ->
               AccessKeys.revoke_node_keys(Access.reload(scope), adapter, :node_deleted)
             end) == {:error, :forbidden}

      assert Adapters.create_adapter(scope, %{name: "Acme hidden"}) == {:error, :forbidden}
      assert AccessKeys.subscribe(scope, adapter) == {:error, :forbidden}
      assert Adapters.rename_adapter(scope, adapter, %{name: "renamed"}) == {:error, :forbidden}
      assert Adapters.delete_adapter(scope, adapter) == {:error, :forbidden}
      # A page's scope is read with what the person is shown as it is now.
      assert Adapters.list_adapters(Access.reload(scope)) == []
      assert Adapters.get_adapter(Access.reload(scope), adapter.public_id) == nil
      assert AccessKeys.list_for_node(Access.reload(scope), adapter) == []
      assert AccessKeys.list_enrolment_codes(Access.reload(scope), adapter) == []

      assert Repo.get!(AccessKey, key.id).revoked_at == nil
      assert Repo.get!(EnrolmentCode, code.id).cancelled_at == nil
      assert {:ok, _key} = AccessKeys.fetch_for_verification(key.key_id)
      assert %Node{deleted_at: nil, name: name} = reload(adapter)
      assert name == adapter.name

      assert entries.() == before
    end

    # The organisation's side asks what the person is shown there, an instance admin too.
    test "the organisation's side still follows what the organisation shows", %{
      scope: scope,
      admin: admin,
      adapter: adapter
    } do
      for asker <- [scope, admin] do
        assert Adapters.connect(asker, adapter) == {:error, :not_found}
        refute Access.can?(Access.reload(asker), :"adapter.read", asker.organisation)
      end
    end

    test "a node's, a pool's and a gateway's keys and codes are revoked and cancelled as before",
         %{scope: scope, others: others, hidden: hidden} do
      revoke_and_cancel_each(scope, hidden, others)
    end
  end

  test "Apiary.Access's tables name no action of a feature the documentation does not differ by" do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Access)
    undocumented = Apiary.Features.all() -- Apiary.Features.documented()

    hidden = for action <- Access.actions(), Access.feature(action) in undocumented, do: action
    assert :"adapter.create" in hidden
    assert :"adapter.disconnect" in hidden

    for action <- hidden do
      refute moduledoc =~ "`#{action}`", "the moduledoc names #{action}"
    end

    refute moduledoc =~ "adapter_key"
    assert moduledoc =~ "`node.create`"
  end
end

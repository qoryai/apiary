defmodule Apiary.Adapters.GrantsTest do
  # The grants of an organisation's connections to the instance's adapters, and the table
  # that keeps them.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures, only: [node_key_fixture: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures, only: [key_scope: 1]

  alias Apiary.{Adapters, Edition, EditionStubs, Repo}
  alias Apiary.Adapters.{Connection, Connections, Feed, Grant, Grants, LinkedPass}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.Ed25519

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{
      scope: scope,
      adapter: connectable.adapter,
      pair: connectable.pair,
      key: connectable.access_key,
      key_scope: key_scope(connectable.access_key)
    }
  end

  # A report of `ref` under the 16 bytes `nonce`, for the connection, for the external
  # account `account`, `1001`, `acme` unless given.
  defp report(ctx, connection, ref, nonce, account \\ %{ref: "1001", title: "acme"}),
    do:
      Grants.report(ctx.key_scope, %{
        connection_id: connection.public_id,
        grant_ref: ref,
        account: account,
        pass_nonce: nonce
      })

  # A new pass of the connected `connection`, pressed by the scope's person, whose return
  # came back linked: the 16 bytes of its nonce.
  defp linked_pass(ctx, connection) do
    :ok = pass_made_earlier(connection.public_id)
    {:ok, _url, {public_id, nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
    token = return_token(ctx.pair.secret, public_id, nonce)
    {:ok, :linked} = Connections.complete_return(ctx.scope, public_id, token, nonce)
    elem(Ed25519.decode(nonce, 16), 1)
  end

  # The live grants, `{connection id, ref}`, of the adapter.
  defp live(adapter),
    do:
      Repo.all(
        from g in Grant,
          where: g.adapter_id == ^adapter.id and g.state == :live,
          order_by: [g.connection_id, g.grant_ref],
          select: {g.connection_id, g.grant_ref}
      )

  # The adapter's grant entries, as the feed keeps them.
  defp grant_entries(adapter),
    do:
      for(
        %{kind: "grant", data: data} <- Feed.entries(adapter),
        do: {data["connection_id"], data["grant_ref"], data["status"]}
      )

  defp reports,
    do: Repo.all(from e in Entry, where: e.action == "adapter.report_grant", order_by: e.id)

  describe "the table" do
    defp insert(attrs) do
      now = DateTime.utc_now()

      Repo.insert_all(Grant, [
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            public_id: Apiary.PublicId.generate("ag"),
            grant_ref: "G_1",
            state: :live,
            pass_nonce: :crypto.strong_rand_bytes(16),
            granted_at: now,
            inserted_at: now,
            updated_at: now
          },
          attrs
        )
      ])
    end

    defp refused(fun) do
      %Postgrex.Error{postgres: %{constraint: constraint}} = assert_raise(Postgrex.Error, fun)
      constraint
    end

    test "a grant stays with its connection's organisation and adapter", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _nonce} = connection_fixture(scope, adapter)
      %{scope: other} = sign_up_fixture()
      second = adapter_fixture()

      base = %{
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        connection_id: connection.id
      }

      assert {1, _} = insert(base)

      for change <- [
            %{organisation_id: other.organisation.id, grant_ref: "G_2"},
            %{adapter_id: second.id, grant_ref: "G_3"}
          ] do
        assert refused(fn -> insert(Map.merge(base, change)) end) ==
                 "adapter_grants_connection_id_fkey"
      end
    end

    test "one live grant per adapter and ref, one per pass, and its states hold together", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _nonce} = connection_fixture(scope, adapter)
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, adapter)
      nonce = :crypto.strong_rand_bytes(16)

      base = %{
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        connection_id: connection.id
      }

      assert {1, _} = insert(Map.put(base, :pass_nonce, nonce))

      # The same ref, live, under another organisation's connection of the adapter.
      assert refused(fn ->
               insert(%{
                 organisation_id: other.organisation.id,
                 adapter_id: adapter.id,
                 connection_id: theirs.id
               })
             end) == "adapter_grants_live_index"

      # The same pass for a second grant of the connection.
      assert refused(fn -> insert(Map.merge(base, %{grant_ref: "G_2", pass_nonce: nonce})) end) ==
               "adapter_grants_connection_id_pass_nonce_index"

      now = DateTime.utc_now()
      ended = %{state: :ended, ended_at: now, ended_reason: :connection_ended}

      # An ended grant leaves its ref free.
      assert {1, _} = insert(Map.merge(base, ended))

      for {attrs, constraint} <- [
            {Map.put(ended, :public_id, "ag_x"), "adapter_grants_public_id_check"},
            {Map.put(ended, :grant_ref, ""), "adapter_grants_grant_ref_check"},
            {Map.put(ended, :grant_ref, String.duplicate("g", 201)),
             "adapter_grants_grant_ref_check"},
            {Map.put(ended, :pass_nonce, <<0::120>>), "adapter_grants_pass_nonce_check"},
            {%{ended | state: :live}, "adapter_grants_state_check"},
            {%{state: :ended, grant_ref: "G_3"}, "adapter_grants_state_check"},
            {%{state: :ended, ended_at: now}, "adapter_grants_ended_reason_check"},
            {%{grant_ref: "G_4", ended_reason: :connection_ended},
             "adapter_grants_ended_reason_check"}
          ] do
        assert refused(fn -> insert(Map.merge(base, attrs)) end) == constraint, inspect(attrs)
      end

      assert refused(fn ->
               Repo.update_all(from(g in "adapter_grants", where: g.pass_nonce == ^nonce),
                 set: [ended_reason: "adapter_reported"]
               )
             end) == "adapter_grants_ended_reason_check"
    end
  end

  describe "a report" do
    test "under a linked pass adds the grant, once, with its feed entry and trail entry",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      nonce = connection.pass_nonce

      assert {:ok, %Grant{state: :live, grant_ref: "G_1", pass_nonce: ^nonce} = grant} =
               report(ctx, connection, "G_1", nonce)

      assert grant.organisation_id == ctx.scope.organisation.id
      assert String.starts_with?(grant.public_id, "ag_")
      assert live(ctx.adapter) == [{connection.id, "G_1"}]
      assert grant_entries(ctx.adapter) == [{connection.public_id, "G_1", "linked"}]

      assert %LinkedPass{reported_at: %DateTime{}} =
               Repo.get_by!(LinkedPass, connection_id: connection.id)

      assert [
               %Entry{
                 organisation_id: trail,
                 actor_kind: :access_key,
                 subject_id: subject,
                 details: details
               }
             ] = reports()

      assert {trail, subject} == {Edition.instance_organisation_id(), ctx.adapter.id}

      assert details == %{
               "connection_id" => connection.public_id,
               "grant_id" => grant.public_id,
               "replaced" => false
             }

      # The same report again, and another ref under the same nonce: the nonce is spent,
      # and the grant stays as it was.
      for ref <- ["G_1", "G_2"] do
        assert report(ctx, connection, ref, nonce) == {:error, :pass_unknown}
      end

      assert Repo.reload!(grant) == grant
      assert live(ctx.adapter) == [{connection.id, "G_1"}]
      assert length(grant_entries(ctx.adapter)) == 1
      assert length(reports()) == 1
    end

    test "of a ref the connection holds, under a newer linked pass, replaces it in place",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      {:ok, first} = report(ctx, connection, "G_1", connection.pass_nonce)
      second_nonce = linked_pass(ctx, connection)

      assert {:ok, %Grant{id: id, pass_nonce: ^second_nonce} = second} =
               report(ctx, connection, "G_1", second_nonce)

      assert id == first.id
      assert DateTime.compare(second.granted_at, first.granted_at) == :gt
      assert live(ctx.adapter) == [{connection.id, "G_1"}]

      assert grant_entries(ctx.adapter) == [
               {connection.public_id, "G_1", "linked"},
               {connection.public_id, "G_1", "linked"}
             ]

      assert [_, %Entry{details: %{"replaced" => true}}] = reports()
    end

    test "under an older linked pass is accepted after a newer pass came back linked", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      second_nonce = linked_pass(ctx, connection)

      assert {:ok, _} = report(ctx, connection, "G_2", second_nonce)
      assert {:ok, _} = report(ctx, connection, "G_1", connection.pass_nonce)
      assert live(ctx.adapter) == [{connection.id, "G_1"}, {connection.id, "G_2"}]
    end

    test "under a nonce of no linked pass of the connection is refused, pass_unknown", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)

      # A pass pressed but not returned, a refused return's, another connection's, and one
      # never made.
      :ok = pass_made_earlier(connection.public_id)
      {:ok, _url, {_id, pressed}} = Adapters.connect(ctx.scope, ctx.adapter)
      pressed = elem(Ed25519.decode(pressed, 16), 1)

      for nonce <- [pressed, theirs.pass_nonce, :crypto.strong_rand_bytes(16)] do
        assert report(ctx, connection, "G_1", nonce) == {:error, :pass_unknown}
      end

      :ok = pass_made_earlier(connection.public_id)
      {:ok, _url, {public_id, refused}} = Adapters.connect(ctx.scope, ctx.adapter)

      token =
        return_token(ctx.pair.secret, public_id, refused, outcome: :refused, reason: :grant_taken)

      {:ok, {:refused, :grant_taken}} =
        Connections.complete_return(ctx.scope, public_id, token, refused)

      assert report(ctx, connection, "G_1", elem(Ed25519.decode(refused, 16), 1)) ==
               {:error, :pass_unknown}

      assert live(ctx.adapter) == []
      assert grant_entries(ctx.adapter) == []
      assert reports() == []
    end

    test "of a ref live under another organisation's connection is refused, grant_taken",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, _} = report(ctx, theirs, "G_1", theirs.pass_nonce)

      assert report(ctx, connection, "G_1", connection.pass_nonce) == {:error, :grant_taken}
      assert live(ctx.adapter) == [{theirs.id, "G_1"}]
      assert Repo.get_by!(LinkedPass, connection_id: connection.id).reported_at == nil

      # Once their connection ends, its grant ends with it, and the ref is free.
      {:ok, _} = Connections.end_connection(ctx.key_scope, theirs.public_id)
      assert {:ok, _} = report(ctx, connection, "G_1", connection.pass_nonce)
      assert live(ctx.adapter) == [{connection.id, "G_1"}]

      # Another adapter's grant of the same ref is apart.
      second = connectable_adapter_fixture()
      {mine, _nonce} = connection_fixture(ctx.scope, second.adapter, :connected)

      assert {:ok, _} =
               Grants.report(key_scope(second.access_key), %{
                 connection_id: mine.public_id,
                 grant_ref: "G_1",
                 account: %{ref: "1001", title: "acme"},
                 pass_nonce: mine.pass_nonce
               })
    end

    test "the order: forbidden, then unknown, ended and suspended, then the pass", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      %{access_key: node_key} = node_key_fixture(ctx.scope, node_fixture(ctx.scope))
      other = connectable_adapter_fixture()
      unknown = :crypto.strong_rand_bytes(16)

      assert Grants.report(key_scope(node_key), %{
               connection_id: connection.public_id,
               grant_ref: "G_1",
               account: %{ref: "1001", title: "acme"},
               pass_nonce: connection.pass_nonce
             }) == {:error, :forbidden}

      # Another adapter's key, an id of no connection, and a pending connection: unknown.
      assert Grants.report(key_scope(other.access_key), %{
               connection_id: connection.public_id,
               grant_ref: "G_1",
               account: %{ref: "1001", title: "acme"},
               pass_nonce: connection.pass_nonce
             }) == {:error, :unknown}

      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, ctx.adapter, :pending)

      for id <- ["ac_f1xt0re000000000", "nope", pending.public_id] do
        assert Grants.report(ctx.key_scope, %{
                 connection_id: id,
                 grant_ref: "G_1",
                 account: %{ref: "1001", title: "acme"},
                 pass_nonce: pending.pass_nonce
               }) == {:error, :unknown}
      end

      # Out of use: suspended before the pass is looked at.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert report(ctx, connection, "G_1", unknown) == {:error, :suspended}
      Process.put(:out_of_use, [])

      # Ended: ended before the pass is looked at.
      {:ok, _} = Connections.end_connection(ctx.key_scope, connection.public_id)
      assert report(ctx, connection, "G_1", unknown) == {:error, :ended}
      assert report(ctx, connection, "G_1", connection.pass_nonce) == {:error, :ended}

      assert live(ctx.adapter) == []
      assert reports() == []
    end
  end

  describe "a connection's end" do
    test "ends its grants, writes their unlinked entries after its collections', and frees the refs",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      second_nonce = linked_pass(ctx, connection)
      {:ok, one} = report(ctx, connection, "G_1", connection.pass_nonce)
      {:ok, _two} = report(ctx, connection, "G_2", second_nonce)

      {:ok, :accepted} =
        Apiary.Adapters.Collections.post_listing(ctx.key_scope, %{
          time: DateTime.utc_now(:second),
          connection_id: connection.public_id,
          collections: [
            %{
              ref: "TRK",
              url: "https://tracker.example.com/TRK",
              title: "Tracker",
              grant_ref: "G_1",
              target: nil
            }
          ],
          listing: %{id: "l1", part: 1, started_at: DateTime.utc_now(:second), complete: true}
        })

      {:ok, _} = Connections.end_connection(ctx.key_scope, connection.public_id)

      assert %Grant{state: :ended, ended_reason: :connection_ended, ended_at: %DateTime{}} =
               Repo.reload!(one)

      assert live(ctx.adapter) == []

      assert grant_entries(ctx.adapter) == [
               {connection.public_id, "G_1", "linked"},
               {connection.public_id, "G_2", "linked"},
               {connection.public_id, "G_1", "unlinked"},
               {connection.public_id, "G_2", "unlinked"}
             ]

      kinds = for %{kind: kind} <- Feed.entries(ctx.adapter), do: kind
      assert Enum.take(kinds, -2) == ["grant", "grant"]
    end

    test "an organisation's purge and the adapter's deletion end the grants too", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      {:ok, _} = report(ctx, connection, "G_1", connection.pass_nonce)

      1 = Connections.end_for_organisation(ctx.scope.organisation.id)
      assert live(ctx.adapter) == []
      assert List.last(grant_entries(ctx.adapter)) == {connection.public_id, "G_1", "unlinked"}

      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, _} = report(ctx, theirs, "G_1", theirs.pass_nonce)

      {:ok, _} = Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)

      assert %Grant{state: :ended, ended_reason: :connection_ended} =
               Repo.get_by!(Grant, connection_id: theirs.id)
    end

    test "the connection stays connected with no grant, and adds one again", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      assert live(ctx.adapter) == []
      nonce = linked_pass(ctx, connection)
      assert %Connection{state: :connected} = Repo.reload!(connection)
      assert {:ok, _} = report(ctx, connection, "G_1", nonce)
    end
  end

  describe "the copy the adapter reads" do
    test "lists the grants of its connections that have not ended, and no other adapter's",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      second_nonce = linked_pass(ctx, connection)
      {:ok, _} = report(ctx, connection, "G_2", connection.pass_nonce)
      {:ok, _} = report(ctx, connection, "G_1", second_nonce)

      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, _} = report(ctx, theirs, "G_3", theirs.pass_nonce)

      %{scope: third} = sign_up_fixture()
      {ended, _nonce} = connection_fixture(third, ctx.adapter, :connected)
      {:ok, _} = report(ctx, ended, "G_4", ended.pass_nonce)
      {:ok, _} = Connections.end_connection(ctx.key_scope, ended.public_id)

      second = connectable_adapter_fixture()
      {elsewhere, _nonce} = connection_fixture(ctx.scope, second.adapter, :connected)

      {:ok, _} =
        Grants.report(key_scope(second.access_key), %{
          connection_id: elsewhere.public_id,
          grant_ref: "G_5",
          account: %{ref: "1001", title: "acme"},
          pass_nonce: elsewhere.pass_nonce
        })

      expected =
        Enum.sort([
          {connection.public_id, "G_1"},
          {connection.public_id, "G_2"},
          {theirs.public_id, "G_3"}
        ])

      assert Grants.list_for_adapter(ctx.key_scope) == {:ok, expected}

      # An organisation out of use keeps its grants in the copy.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [other.organisation.id])
      assert Grants.list_for_adapter(ctx.key_scope) == {:ok, expected}
    end

    test "is refused to a key that is not an adapter's", ctx do
      %{access_key: node_key} = node_key_fixture(ctx.scope, node_fixture(ctx.scope))
      assert Grants.list_for_adapter(key_scope(node_key)) == {:error, :forbidden}
      assert Grants.list_for_adapter(nil) == {:error, :forbidden}
    end
  end

  describe "live_for_organisation/3" do
    test "finds the organisation's live grant of a ref, and no other organisation's", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      {:ok, grant} = report(ctx, connection, "G_1", connection.pass_nonce)
      %{scope: other} = sign_up_fixture()

      assert %Grant{id: id} =
               Grants.live_for_organisation(ctx.adapter.id, "G_1", ctx.scope.organisation.id)

      assert id == grant.id
      assert Grants.live_for_organisation(ctx.adapter.id, "G_1", other.organisation.id) == nil
      assert Grants.live_for_organisation(ctx.adapter.id, "G_2", ctx.scope.organisation.id) == nil

      {:ok, _} = Connections.end_connection(ctx.key_scope, connection.public_id)
      assert Grants.live_for_organisation(ctx.adapter.id, "G_1", ctx.scope.organisation.id) == nil
    end
  end
end

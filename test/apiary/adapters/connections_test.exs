defmodule Apiary.Adapters.ConnectionsTest do
  # An organisation's connections to the instance's adapters: starting one,
  # connecting it by the return the person brings back, what the adapter's key
  # finds through one, recording its first listing, ending it, the pools it lets
  # an adapter serve, and the table that keeps them. It runs where the feature
  # adapters belong to is on; `Apiary.AdaptersWithoutFactoryTest` turns it off.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, AccessKeys, Adapters, Deletion, Edition, EditionStubs, Nodes}
  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{ConnectPass, Connection, Connections}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  # The edition refuses whatever a scope of the organisations a test names asks, as an
  # edition that suspends an organisation answers for it (`c:Apiary.Edition.check/3`).
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
    connectable = connectable_adapter_fixture(%{name: "Acme tracker"})

    %{
      scope: scope,
      admin: instance_admin_scope(),
      adapter: connectable.adapter,
      pair: connectable.pair,
      key: connectable.access_key
    }
  end

  defp reload(%Connection{id: id}), do: Repo.get!(Connection, id)

  # The verified key's scope, as a signed request carries it.
  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  defp connected_pool(scope, adapter) do
    pool = pool_fixture(scope)
    {:ok, pool} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})
    pool
  end

  defp nonce_bytes(nonce), do: elem(Ed25519.decode(nonce, 16), 1)

  describe "connecting" do
    test "an owner starts a pending connection, with a pass for it whose nonce it keeps", %{
      scope: scope,
      adapter: adapter
    } do
      assert {:ok, url, {public_id, nonce}} = Adapters.connect(scope, adapter)
      assert "https://tracker.example.com/connect?state=" <> pass = url

      assert {:ok, %{adapter_id: adapter_id, connection_id: ^public_id, nonce: bytes}} =
               ConnectPass.verify(pass, Apiary.SigningKey.public_key())

      assert adapter_id == adapter.public_id
      assert Ed25519.encode(bytes) == nonce
      assert Connection.public_id?(public_id)

      assert %Connection{
               state: :pending,
               organisation_id: organisation_id,
               adapter_id: id,
               created_by_id: user_id,
               pass_nonce: ^bytes,
               pass_nonce_used_at: nil,
               connected_at: nil,
               listed_at: nil,
               ended_at: nil
             } = Repo.get_by!(Connection, public_id: public_id)

      assert {organisation_id, id, user_id} ==
               {scope.organisation.id, adapter.id, scope.user.id}
    end

    test "each press while pending is a new pass for the same connection, by whoever pressed",
         %{scope: scope, adapter: adapter} do
      %{scope: admin, user: other} = member_fixture(scope, :admin)
      {:ok, _url, {public_id, first}} = Adapters.connect(scope, adapter)
      {:ok, _url, {^public_id, second}} = Adapters.connect(admin, adapter)

      refute first == second

      assert %Connection{created_by_id: by, pass_nonce: kept} =
               Repo.get_by!(Connection, public_id: public_id)

      assert by == other.id
      assert Ed25519.encode(kept) == second
      assert Repo.aggregate(Connection, :count) == 1
    end

    test "an organisation connected, and listed, is told so, and changes nothing", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _nonce} = connection_fixture(scope, adapter, :listed)
      assert Adapters.connect(scope, adapter) == {:error, :connected}
      assert reload(connection) == connection
    end

    test "an ended connection is never taken back: a new one is made", %{
      scope: scope,
      adapter: adapter,
      key: key
    } do
      {connection, _nonce} = connection_fixture(scope, adapter, :listed)
      {:ok, _ended} = Connections.end_connection(key_scope(key), connection.public_id)

      {:ok, _url, {public_id, _nonce}} = Adapters.connect(scope, adapter)
      refute public_id == connection.public_id
      assert reload(connection).state == :ended
    end

    test "each organisation has a separate connection to an adapter", %{
      scope: scope,
      adapter: adapter
    } do
      %{scope: other} = sign_up_fixture()
      {:ok, _url, {first, _}} = Adapters.connect(scope, adapter)
      {:ok, _url, {second, _}} = Adapters.connect(other, adapter)
      refute first == second
    end

    test "only an owner or an admin connects, an adapter in use with an address and a key",
         %{scope: scope, adapter: adapter, admin: admin} do
      %{scope: member} = member_fixture(scope, :member)
      assert Adapters.connect(member, adapter) == {:error, :forbidden}

      bare = adapter_fixture()
      assert Adapters.connect(scope, bare) == {:error, :no_connect_url}

      Repo.update_all(from(n in Node, where: n.id == ^bare.id),
        set: [connect_url: "https://tracker.example.com/c?x=1#top"]
      )

      assert Adapters.connect(scope, bare) == {:error, :no_key}
      %{access_key: _key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(admin, bare)

      assert {:ok, "https://tracker.example.com/c?x=1&state=" <> rest, _} =
               Adapters.connect(scope, Repo.get!(Node, bare.id))

      assert String.ends_with?(rest, "#top")

      {:ok, deleted} = Adapters.delete_adapter(admin, adapter)
      assert Adapters.connect(scope, deleted) == {:error, :not_found}

      assert Repo.aggregate(from(c in Connection, where: c.adapter_id == ^adapter.id), :count) ==
               0
    end
  end

  describe "the expiry of each new pass" do
    @at ~U[2026-10-16 12:00:00.250000Z]

    # A press at `now`, as `Apiary.Adapters.connect/2` makes it: the connection, the
    # `expires_at` the pass says, read from its payload, and the pass.
    defp press(scope, adapter, now) do
      assert {:ok, {connection, pass}} =
               Repo.transact(fn ->
                 with {:ok, connection, pass} <-
                        Connections.start(scope, adapter, ConnectPass.new_nonce(), now: now),
                      do: {:ok, {connection, pass}}
               end)

      {connection, signed_expiry(pass), pass}
    end

    defp signed_expiry(pass) do
      [payload, _signature] = String.split(pass, ".")
      %{"expires_at" => at} = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      {:ok, time, 0} = DateTime.from_iso8601(at)
      time
    end

    test "two presses in the same second: the second expires one second after the first", %{
      scope: scope,
      adapter: adapter
    } do
      {first, first_at, _} = press(scope, adapter, @at)
      assert first_at == ~U[2026-10-16 12:15:00Z]
      assert reload(first).pass_expires_at == first_at

      {second, second_at, _} = press(scope, adapter, DateTime.add(@at, 500, :millisecond))
      assert second.id == first.id
      assert second_at == ~U[2026-10-16 12:15:01Z]
      assert reload(second).pass_expires_at == second_at
    end

    test "a clock that stepped back: the next pass still expires one second after the last", %{
      scope: scope,
      adapter: adapter
    } do
      {_first, first_at, _} = press(scope, adapter, @at)
      {second, second_at, _} = press(scope, adapter, DateTime.add(@at, -60, :second))

      assert second_at == DateTime.add(first_at, 1, :second)
      assert reload(second).pass_expires_at == second_at
    end

    test "a press later on: the pass expires validity/0 seconds after it", %{
      scope: scope,
      adapter: adapter
    } do
      {_first, _first_at, _} = press(scope, adapter, @at)
      {second, second_at, _} = press(scope, adapter, DateTime.add(@at, 120, :second))

      assert second_at == ~U[2026-10-16 12:17:00Z]
      assert reload(second).pass_expires_at == second_at
    end

    test "many quick presses: each expires one second after the last, past validity/0", %{
      scope: scope,
      adapter: adapter
    } do
      times = for _ <- 1..3, do: scope |> press(adapter, @at) |> elem(1)

      assert times ==
               [~U[2026-10-16 12:15:00Z], ~U[2026-10-16 12:15:01Z], ~U[2026-10-16 12:15:02Z]]
    end

    test "a connection made before its pass expiry was kept: the next pass expires as a first",
         %{scope: scope, adapter: adapter} do
      {first, _first_at, _} = press(scope, adapter, @at)

      Repo.update_all(from(c in Connection, where: c.id == ^first.id),
        set: [pass_expires_at: nil]
      )

      {second, second_at, _} = press(scope, adapter, @at)
      assert second_at == ~U[2026-10-16 12:15:00Z]
      assert reload(second).pass_expires_at == second_at
    end

    test "a new connection in place of a replaced one: its pass expires as a first", %{
      scope: scope,
      adapter: adapter
    } do
      {first, first_at, _} = press(scope, adapter, @at)
      now = DateTime.utc_now()

      first
      |> Ecto.Changeset.change(state: :connected, connected_at: now, pass_nonce_used_at: now)
      |> Repo.update!()

      {second, second_at, _} = press(scope, adapter, @at)
      refute second.id == first.id
      assert second_at == first_at
      assert reload(second).pass_expires_at == second_at

      assert %Connection{state: :ended, ended_reason: :replaced, pass_expires_at: ^first_at} =
               reload(first)
    end

    test "the expiry kept is the signed one, for each press of Install", %{
      scope: scope,
      adapter: adapter
    } do
      for _ <- 1..2 do
        {:ok, url, {public_id, _nonce}} = Adapters.connect(scope, adapter)
        "https://tracker.example.com/connect?state=" <> pass = url

        assert {:ok, %{expires_at: expires_at}} =
                 ConnectPass.verify(pass, Apiary.SigningKey.public_key(),
                   now: DateTime.add(signed_expiry(pass), -1, :second)
                 )

        assert Repo.get_by!(Connection, public_id: public_id).pass_expires_at == expires_at
      end
    end
  end

  describe "the return" do
    setup %{scope: scope, adapter: adapter} do
      {:ok, _url, {public_id, nonce}} = Adapters.connect(scope, adapter)
      %{connection: Repo.get_by!(Connection, public_id: public_id), nonce: nonce}
    end

    test "linked connects the connection, not yet listed, which the key then reaches; the nonce is used",
         %{scope: scope, pair: pair, key: key, connection: connection, nonce: nonce} do
      token = return_token(pair.secret, connection.public_id, nonce)

      # Before the return, the key and a listing find it unknown (`connection_unknown`).
      assert Connections.connection_for_key(
               key_scope(key),
               connection.public_id,
               :"source_item.post"
             ) == {:error, :unknown}

      assert Connections.mark_listed(connection) == {:error, :unknown}

      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:ok, :linked}

      assert %Connection{
               state: :connected,
               connected_at: %DateTime{},
               listed_at: nil,
               pass_nonce_used_at: %DateTime{}
             } = reload(connection)

      assert {:ok, %Connection{id: id}, _scope} =
               Connections.connection_for_key(
                 key_scope(key),
                 connection.public_id,
                 :"source_item.post"
               )

      assert id == connection.id

      # Once: the same return again is not found.
      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:error, :not_found}
    end

    test "refused and cancelled change nothing but the nonce, which is used", %{
      scope: scope,
      adapter: adapter,
      pair: pair,
      connection: connection
    } do
      for reason <- Apiary.Adapters.ReturnToken.reasons() do
        {:ok, _url, {_id, nonce}} = Adapters.connect(scope, adapter)

        token =
          return_token(pair.secret, connection.public_id, nonce,
            outcome: :refused,
            reason: reason
          )

        assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
                 {:ok, {:refused, reason}}

        assert %Connection{state: :pending, connected_at: nil, pass_nonce_used_at: %DateTime{}} =
                 reload(connection)
      end

      {:ok, _url, {_id, nonce}} = Adapters.connect(scope, adapter)
      token = return_token(pair.secret, connection.public_id, nonce, outcome: :cancelled)

      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:ok, :cancelled}

      assert %Connection{state: :pending, connected_at: nil} = reload(connection)
    end

    test "connected and not yet listed, a press ends it as replaced, clears its pools, starts anew",
         %{
           scope: scope,
           adapter: adapter,
           pair: pair,
           key: key,
           connection: connection,
           nonce: nonce
         } do
      token = return_token(pair.secret, connection.public_id, nonce)
      {:ok, :linked} = Connections.complete_return(scope, connection.public_id, token, nonce)
      connected = reload(connection)
      %{scope: admin, user: other} = member_fixture(scope, :admin)

      # A pool may name the adapter as soon as the return connected it; one served by
      # another adapter is kept.
      pool = connected_pool(scope, adapter)
      second_adapter = connectable_adapter_fixture()
      {_ours, _} = connection_fixture(scope, second_adapter.adapter, :connected)
      kept = connected_pool(scope, second_adapter.adapter)

      assert {:ok, url, {public_id, second}} = Adapters.connect(admin, adapter)
      refute public_id == connection.public_id
      refute second == nonce

      # The pass names the new connection, with its nonce.
      "https://tracker.example.com/connect?state=" <> pass = url

      assert {:ok, %{connection_id: ^public_id, nonce: bytes}} =
               ConnectPass.verify(pass, Apiary.SigningKey.public_key())

      assert Ed25519.encode(bytes) == second

      # The connected one ended, with its pass, its person and the time it connected as they
      # were, and the pool it served is served by none.
      assert %Connection{state: :ended, ended_at: %DateTime{}, ended_reason: :replaced} =
               ended = reload(connection)

      fields = [:pass_nonce, :pass_nonce_used_at, :created_by_id, :connected_at, :listed_at]
      assert Map.take(ended, fields) == Map.take(connected, fields)
      assert {ended.pass_nonce, ended.created_by_id} == {nonce_bytes(nonce), scope.user.id}
      assert Repo.get!(Node, pool.id).served_by_id == nil
      assert Repo.get!(Node, kept.id).served_by_id == second_adapter.adapter.id

      # The new one is pending, started by the admin with the new pass.
      assert %Connection{
               state: :pending,
               connected_at: nil,
               pass_nonce_used_at: nil,
               created_by_id: by,
               pass_nonce: ^bytes
             } = fresh = Repo.get_by!(Connection, public_id: public_id)

      assert by == other.id

      assert Repo.all(
               from c in Connection,
                 where: c.adapter_id == ^adapter.id and is_nil(c.ended_at),
                 select: c.public_id
             ) == [public_id]

      # The adapter's key reaches the old one no more, and the new one not yet.
      key_scope = key_scope(key)

      assert Connections.connection_for_key(key_scope, connection.public_id, :"source_item.post") ==
               {:error, :ended}

      assert Connections.mark_listed(connected) == {:error, :ended}

      assert Connections.connection_for_key(key_scope, public_id, :"source_item.post") ==
               {:error, :unknown}

      assert Connections.mark_listed(fresh) == {:error, :unknown}

      # A return for the old one, or under the old pass, is not found; so is the new pass's
      # return brought by someone else than the admin, or for the old connection.
      for {id, token, session, presser} <- [
            {connection.public_id, token, nonce, scope},
            {connection.public_id, return_token(pair.secret, connection.public_id, second),
             second, admin},
            {public_id, return_token(pair.secret, public_id, nonce), nonce, scope},
            {public_id, return_token(pair.secret, public_id, nonce), second, admin}
          ] do
        assert Connections.complete_return(presser, id, token, session) == {:error, :not_found}
      end

      linked = return_token(pair.secret, public_id, second)

      assert Connections.complete_return(scope, public_id, linked, second) ==
               {:error, :wrong_person}

      assert reload(connection) == ended
      assert reload(fresh) == fresh

      # The new one is connected by the return under its pass, then listed, and a press is
      # refused.
      assert Connections.complete_return(admin, public_id, linked, second) == {:ok, :linked}

      assert {:ok, %Connection{id: id}, _scope} =
               Connections.connection_for_key(key_scope, public_id, :"source_item.post")

      assert id == fresh.id

      assert {:ok, %Connection{state: :connected, listed_at: %DateTime{}}} =
               Connections.mark_listed(fresh)

      assert Adapters.connect(scope, adapter) == {:error, :connected}

      # Each press of this adapter left its entry, naming its connection; the end left
      # none. In the order written: the two entries can share a time, and the ids are
      # monotonic.
      assert Repo.all(
               from e in Entry,
                 where: e.subject_id == ^scope.organisation.id,
                 where: like(e.action, "adapter.%"),
                 where: e.details["public_id"] == ^adapter.public_id,
                 order_by: [asc: e.id],
                 select: {e.action, e.details["connection_id"]}
             ) == [
               {"adapter.connect", connection.public_id},
               {"adapter.connect", public_id}
             ]
    end

    test "the adapter's disconnect ends a pending connection, and its return is not found after",
         %{
           scope: scope,
           adapter: adapter,
           pair: pair,
           key: key,
           connection: connection,
           nonce: nonce
         } do
      key_scope = key_scope(key)
      other = connectable_adapter_fixture()

      # To another adapter's key it is unknown, as an id that names none is.
      assert Connections.end_connection(key_scope(other.access_key), connection.public_id) ==
               {:error, :unknown}

      assert Connections.end_connection(key_scope, "ac_0000000000000000") == {:error, :unknown}
      assert reload(connection) == connection

      assert {:ok,
              %Connection{
                state: :ended,
                ended_reason: :adapter_reported,
                ended_at: %DateTime{},
                connected_at: nil
              }} = Connections.end_connection(key_scope, connection.public_id)

      ended = reload(connection)

      assert Connections.complete_return(
               scope,
               connection.public_id,
               return_token(pair.secret, connection.public_id, nonce),
               nonce
             ) == {:error, :not_found}

      assert reload(connection) == ended
      assert Connections.end_connection(key_scope, connection.public_id) == {:error, :ended}

      # Ended, though never connected: the key gets 409 ended, and nothing to act through.
      assert Connections.connection_for_key(key_scope, connection.public_id, :"source_item.post") ==
               {:error, :ended}

      # A press after it starts a new connection.
      assert {:ok, _url, {public_id, _nonce}} = Adapters.connect(scope, adapter)
      refute public_id == connection.public_id
    end

    test "a used, refused or stale return changes no connected connection", %{
      scope: scope,
      adapter: adapter,
      pair: pair,
      connection: connection,
      nonce: first
    } do
      {:ok, _url, {_id, nonce}} = Adapters.connect(scope, adapter)
      linked = return_token(pair.secret, connection.public_id, nonce)
      {:ok, :linked} = Connections.complete_return(scope, connection.public_id, linked, nonce)
      connected = reload(connection)

      for {token, session} <- [
            {linked, nonce},
            {return_token(pair.secret, connection.public_id, nonce, outcome: :cancelled), nonce},
            {return_token(pair.secret, connection.public_id, nonce,
               outcome: :refused,
               reason: :person_not_permitted
             ), nonce},
            {return_token(pair.secret, connection.public_id, first), first}
          ] do
        assert Connections.complete_return(scope, connection.public_id, token, session) ==
                 {:error, :not_found}
      end

      assert reload(connection) == connected

      # Even with its nonce unused, a connected connection takes no return.
      Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
        set: [pass_nonce_used_at: nil]
      )

      assert Connections.complete_return(scope, connection.public_id, linked, nonce) ==
               {:error, :not_found}

      assert reload(connection) == %{connected | pass_nonce_used_at: nil}
    end

    test "a later press makes the earlier pass's return not found", %{
      scope: scope,
      adapter: adapter,
      pair: pair,
      connection: connection,
      nonce: first
    } do
      {:ok, _url, {_id, second}} = Adapters.connect(scope, adapter)
      early = return_token(pair.secret, connection.public_id, first)

      for session <- [first, second] do
        assert Connections.complete_return(scope, connection.public_id, early, session) ==
                 {:error, :not_found}
      end

      assert {:ok, :linked} =
               Connections.complete_return(
                 scope,
                 connection.public_id,
                 return_token(pair.secret, connection.public_id, second),
                 second
               )
    end

    test "every bad, expired or used token is not found, and changes nothing", %{
      scope: scope,
      admin: admin,
      adapter: adapter,
      pair: pair,
      key: key,
      connection: connection,
      nonce: nonce
    } do
      id = connection.public_id
      bytes = nonce_bytes(nonce)
      other_adapter = connectable_adapter_fixture()
      {other, _other_nonce} = connection_fixture(scope, other_adapter.adapter, :pending)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      bad = [
        # 1. not a return, or not signed by a key in use of this connection's adapter
        "",
        nil,
        "not.a-return",
        return_token(Apiary.AccessKeysFixtures.ed25519_key_pair().secret, id, nonce),
        return_token(other_adapter.pair.secret, id, nonce),
        # 2. another connection's id, signed right
        return_token(pair.secret, other.public_id, nonce),
        # 4. another nonce
        return_token(pair.secret, id, :crypto.strong_rand_bytes(16)),
        # 6. expired, or expiring too late to be one made now
        return_token(pair.secret, id, bytes, expires_at: DateTime.add(now, -1, :second)),
        return_token(pair.secret, id, bytes, expires_at: now),
        return_token(pair.secret, id, bytes, expires_at: DateTime.add(now, 400, :second)),
        # against its rules
        return_token(pair.secret, id, bytes, outcome: :refused, reason: nil),
        return_token(pair.secret, id, bytes, payload: %{"version" => 1})
      ]

      for token <- bad do
        assert Connections.complete_return(scope, id, token, nonce) == {:error, :not_found},
               inspect(token)
      end

      good = return_token(pair.secret, id, nonce)

      # The link's id: not a connection's, none, or another one.
      for link <- ["ac_0000000000000000", "na_0123456789abcdef", nil, other.public_id] do
        assert Connections.complete_return(scope, link, good, nonce) == {:error, :not_found}
      end

      assert reload(connection) == connection

      # 1. A revoked key's return.
      {:ok, _} = AccessKeys.revoke_access_key(admin, key)
      assert Connections.complete_return(scope, id, good, nonce) == {:error, :not_found}
      assert reload(connection) == connection

      # 3. Not pending: an ended connection, of a deleted adapter.
      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert Connections.complete_return(scope, id, good, nonce) == {:error, :not_found}
    end

    test "3. a connection that is connected or ended takes no return", %{
      scope: scope,
      adapter: adapter,
      pair: pair,
      key: key,
      connection: connection,
      nonce: nonce
    } do
      {:ok, :linked} =
        Connections.complete_return(
          scope,
          connection.public_id,
          return_token(pair.secret, connection.public_id, nonce),
          nonce
        )

      {:ok, connected} = Connections.mark_listed(reload(connection))
      assert Adapters.connect(scope, adapter) == {:error, :connected}

      # A connected one keeps its nonce; a return under it is refused, used or not.
      Repo.update_all(from(c in Connection, where: c.id == ^connected.id),
        set: [pass_nonce_used_at: nil]
      )

      token = return_token(pair.secret, connection.public_id, nonce)

      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:error, :not_found}

      {:ok, _} = Connections.end_connection(key_scope(key), connection.public_id)

      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:error, :not_found}
    end

    test "7. another person, or another browser, is the wrong person, and changes nothing", %{
      scope: scope,
      pair: pair,
      connection: connection,
      nonce: nonce
    } do
      %{scope: admin} = member_fixture(scope, :admin)
      token = return_token(pair.secret, connection.public_id, nonce)

      # Another admin of the organisation, with the session's nonce.
      assert Connections.complete_return(admin, connection.public_id, token, nonce) ==
               {:error, :wrong_person}

      # The person who started it, in a browser whose session kept no nonce, or another.
      for session <- [nil, "", "x", Ed25519.encode(:crypto.strong_rand_bytes(16)), 42] do
        assert Connections.complete_return(scope, connection.public_id, token, session) ==
                 {:error, :wrong_person}
      end

      assert reload(connection) == connection

      # The right person, in the right browser, takes it after.
      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:ok, :linked}
    end

    test "8. a person no longer an owner or an admin, or out of the organisation, is not found",
         %{adapter: adapter, pair: pair, scope: owner} do
      %{scope: admin, membership: membership} = member_fixture(owner, :admin)
      {:ok, _url, {public_id, nonce}} = Adapters.connect(admin, adapter)
      token = return_token(pair.secret, public_id, nonce)

      {:ok, _} = Organisations.set_member_level(owner, membership.id, :member)

      assert Connections.complete_return(admin, public_id, token, nonce) == {:error, :not_found}

      assert %Connection{state: :pending, pass_nonce_used_at: nil} =
               Repo.get_by!(Connection, public_id: public_id)

      # An organisation marked for deletion takes none either.
      {:ok, _} = Organisations.set_member_level(owner, membership.id, :admin)
      {:ok, _} = Deletion.delete_organisation(owner, owner.organisation.slug)
      assert Connections.complete_return(admin, public_id, token, nonce) == {:error, :not_found}
    end

    test "a scope of no person takes none", %{pair: pair, connection: connection, nonce: nonce} do
      token = return_token(pair.secret, connection.public_id, nonce)

      for scope <- [nil, %Scope{}, Scope.for_instance(nil)] do
        assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
                 {:error, :not_found}
      end
    end
  end

  describe "at the server contract" do
    setup %{scope: scope, adapter: adapter, key: key} do
      {connected, _nonce} = connection_fixture(scope, adapter, :connected)
      %{connected: connected, key_scope: key_scope(key)}
    end

    test "a connected connection is found, with the key's scope narrowed to its organisation",
         %{scope: scope, connected: connected, key_scope: key_scope} do
      assert {:ok, %Connection{id: id} = connection, narrowed} =
               Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post")

      assert id == connected.id
      assert narrowed.organisation.id == scope.organisation.id
      assert narrowed.workspace == nil
      assert narrowed.access_key == key_scope.access_key
      assert narrowed == Scope.for_connection(key_scope, connection)
      assert Access.place(narrowed) == {scope.organisation.id, nil}
    end

    test "unknown: none, another adapter's, one pending, and ours to another adapter's key",
         %{scope: scope, adapter: adapter, connected: connected, key_scope: key_scope} do
      other = connectable_adapter_fixture()
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      {theirs, _nonce} = connection_fixture(scope, other.adapter, :connected)

      for id <- ["ac_0000000000000000", "nope", nil, pending.public_id, theirs.public_id] do
        assert Connections.connection_for_key(key_scope, id, :"source_item.post") ==
                 {:error, :unknown}
      end

      # Another adapter's key, whose rights hold the action: the connection is not its
      # adapter's, so it is unknown to it.
      assert Connections.connection_for_key(
               key_scope(other.access_key),
               connected.public_id,
               :"source_item.post"
             ) == {:error, :unknown}

      assert reload(pending) == pending
      assert reload(connected) == connected
    end

    test "forbidden: rights are decided before any lookup, one answer whatever the id names",
         %{scope: scope, adapter: adapter, connected: connected, key_scope: key_scope} do
      other = connectable_adapter_fixture()
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      {theirs, _nonce} = connection_fixture(scope, other.adapter, :connected)
      {ended, _nonce} = connection_fixture(sign_up_fixture().scope, adapter, :listed)
      {:ok, _} = Connections.end_connection(key_scope, ended.public_id)

      ids = [
        connected.public_id,
        "ac_0000000000000000",
        "nope",
        nil,
        pending.public_id,
        theirs.public_id,
        ended.public_id
      ]

      # An action the key's role does not take: the same answer for a connection it holds
      # and for an id that names none, so the key cannot tell them apart.
      for id <- ids do
        assert Connections.connection_for_key(key_scope, id, :"adapter.read") ==
                 {:error, :forbidden}
      end

      # A node's key, a person's scope, and no scope at all have no rights here.
      %{access_key: node_key} = Apiary.AccessKeysFixtures.access_key_fixture(scope)

      for not_adapter <- [Scope.for_access_key(node_key), scope, nil], id <- ids do
        assert Connections.connection_for_key(not_adapter, id, :"source_item.post") ==
                 {:error, :forbidden}

        assert Connections.end_connection(not_adapter, id) == {:error, :forbidden}
      end

      assert reload(connected) == connected
      assert reload(pending) == pending
      assert reload(theirs) == theirs
    end

    test "a disconnect the key's rights do not take is forbidden before any lookup, one answer whatever the id names",
         %{scope: scope, adapter: adapter, connected: connected, key_scope: key_scope} do
      other = connectable_adapter_fixture()
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      {theirs, _nonce} = connection_fixture(scope, other.adapter, :connected)
      {ended, _nonce} = connection_fixture(sign_up_fixture().scope, adapter, :listed)
      {:ok, _} = Connections.end_connection(key_scope, ended.public_id)
      pool = connected_pool(scope, adapter)

      held = [connected, pending, theirs, ended] |> Enum.map(&reload/1)

      # The edition narrows the key's rights: its role does not take `adapter.disconnect`.
      :ok = Edition.put_test_stub(EditionStubs.NoDisconnect)

      ids = [
        connected.public_id,
        "ac_0000000000000000",
        "nope",
        nil,
        pending.public_id,
        ended.public_id,
        theirs.public_id
      ]

      for id <- ids do
        assert Connections.end_connection(key_scope, id) == {:error, :forbidden}
      end

      # Another adapter's key, narrowed alike, is refused the same for a connection of
      # its adapter and for ours.
      for id <- [theirs.public_id, connected.public_id] do
        assert Connections.end_connection(key_scope(other.access_key), id) ==
                 {:error, :forbidden}
      end

      # Nothing changed, and the key's other actions are as they were.
      assert Enum.map(held, &reload/1) == held
      assert Repo.get!(Node, pool.id).served_by_id == adapter.id

      assert {:ok, _, _} =
               Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post")
    end

    test "end_connection/2's order: forbidden, then unknown, then ended",
         %{adapter: adapter, connected: connected, key_scope: key_scope} do
      other = connectable_adapter_fixture()
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      {:ok, _} = Connections.end_connection(key_scope, connected.public_id)

      # The key's rights take the disconnect: an id it does not hold is unknown, and one
      # that ended is ended.
      assert Connections.end_connection(key_scope, "ac_0000000000000000") == {:error, :unknown}

      assert Connections.end_connection(key_scope(other.access_key), pending.public_id) ==
               {:error, :unknown}

      assert Connections.end_connection(key_scope, connected.public_id) == {:error, :ended}

      # Its rights narrowed, each is forbidden first, and the pending one is not ended.
      :ok = Edition.put_test_stub(EditionStubs.NoDisconnect)

      for id <- ["ac_0000000000000000", connected.public_id, pending.public_id] do
        assert Connections.end_connection(key_scope, id) == {:error, :forbidden}
      end

      assert Connections.end_connection(key_scope(other.access_key), pending.public_id) ==
               {:error, :forbidden}

      assert reload(pending) == pending
    end

    test "the order: forbidden, then unknown, then ended, then suspended",
         %{scope: scope, adapter: adapter, connected: connected, key_scope: key_scope} do
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id])

      # Suspended, and refused for rights first.
      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :suspended}

      assert Connections.connection_for_key(key_scope, connected.public_id, :"adapter.read") ==
               {:error, :forbidden}

      # Pending in an organisation out of use: unknown, not suspended; forbidden first.
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      Process.put(:out_of_use, [scope.organisation.id, second.organisation.id])

      assert Connections.connection_for_key(key_scope, pending.public_id, :"source_item.post") ==
               {:error, :unknown}

      assert Connections.connection_for_key(key_scope, pending.public_id, :"adapter.read") ==
               {:error, :forbidden}

      # Ended in an organisation out of use: ended, not suspended; forbidden first.
      {:ok, _} = Connections.end_connection(key_scope, connected.public_id)

      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :ended}

      assert Connections.connection_for_key(key_scope, connected.public_id, :"adapter.read") ==
               {:error, :forbidden}

      # Another adapter's key gets no 409 for it: the connection is unknown to it.
      other = connectable_adapter_fixture()

      assert Connections.connection_for_key(
               key_scope(other.access_key),
               connected.public_id,
               :"source_item.post"
             ) == {:error, :unknown}

      assert Connections.end_connection(key_scope(other.access_key), connected.public_id) ==
               {:error, :unknown}
    end

    test "409 ended for one that ended before it connected",
         %{adapter: adapter, key_scope: key_scope} do
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)

      # Ended and never connected: 409 ended, as for one ended after it connected.
      Repo.update_all(from(c in Connection, where: c.id == ^pending.id),
        set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
      )

      assert Connections.connection_for_key(key_scope, pending.public_id, :"source_item.post") ==
               {:error, :ended}
    end

    test "409 ended for a pending one the organisation's purge ended; unknown to another adapter's key",
         %{adapter: adapter, key_scope: key_scope} do
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, adapter, :pending)
      other = connectable_adapter_fixture()

      assert Connections.connection_for_key(key_scope, pending.public_id, :"source_item.post") ==
               {:error, :unknown}

      # The purge's step that ends the organisation's connections
      # (`Apiary.Deletion.purge_organisation/1`).
      assert Connections.end_for_organisation(second.organisation.id) == 1

      assert %Connection{state: :ended, ended_reason: :organisation_deleted, connected_at: nil} =
               ended = reload(pending)

      assert Connections.connection_for_key(key_scope, pending.public_id, :"source_item.post") ==
               {:error, :ended}

      assert Connections.end_connection(key_scope, pending.public_id) == {:error, :ended}
      assert Connections.mark_listed(pending) == {:error, :ended}

      # Another adapter's key finds it unknown, and an action the key does not take is
      # forbidden first: a 409 goes to the connection's adapter alone.
      assert Connections.connection_for_key(
               key_scope(other.access_key),
               pending.public_id,
               :"source_item.post"
             ) == {:error, :unknown}

      assert Connections.end_connection(key_scope(other.access_key), pending.public_id) ==
               {:error, :unknown}

      assert Connections.connection_for_key(key_scope, pending.public_id, :"adapter.read") ==
               {:error, :forbidden}

      assert reload(pending) == ended
    end

    test "409 ended, then 409 suspended, in that order", %{
      scope: scope,
      connected: connected,
      key_scope: key_scope
    } do
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id])

      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :suspended}

      {:ok, _} = Connections.end_connection(key_scope, connected.public_id)

      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :ended}
    end

    test "suspended while its organisation is marked, or the edition refuses it, and back after",
         %{scope: scope, connected: connected, key_scope: key_scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :suspended}

      {:ok, _} = Deletion.restore_organisation(scope, scope.organisation.id)

      assert {:ok, _, _} =
               Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post")

      Edition.put_test_stub(Suspends)
      Suspends.put([scope.organisation.id])

      assert Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post") ==
               {:error, :suspended}

      # The scope of the key carries no organisation, which the edition does not refuse.
      assert {:ok, _adapter} = Adapters.for_key(key_scope, :"source_item.post")
      Suspends.put([])

      assert {:ok, _, _} =
               Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post")
    end

    test "the narrowed scope acts on its organisation and that connection, nothing else", %{
      scope: scope,
      adapter: adapter,
      connected: connected,
      key_scope: key_scope
    } do
      {:ok, connection, narrowed} =
        Connections.connection_for_key(key_scope, connected.public_id, :"source_item.post")

      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, adapter, :connected)
      second = connectable_adapter_fixture()
      {of_another, _nonce} = connection_fixture(scope, second.adapter, :connected)

      assert Access.check(narrowed, :"source_item.post", scope.organisation) == :ok
      assert Access.check(narrowed, :"source_item.post", connection) == :ok
      assert Access.check(narrowed, :"source_item.post", adapter) == :ok

      for subject <- [other.organisation, theirs, of_another, scope.workspace, second.adapter] do
        assert Access.check(narrowed, :"source_item.post", subject) == {:error, :not_found}
      end

      # The scope of the key reaches no organisation.
      assert Access.check(key_scope, :"source_item.post", scope.organisation) ==
               {:error, :not_found}

      # A person's role holds nothing the key's does, narrowed or not.
      assert Access.check(narrowed, :"adapter.read", scope.organisation) == {:error, :forbidden}
    end

    test "mark_listed/1 records the first listing of a connected one, once", %{
      adapter: adapter,
      connected: connected,
      key_scope: key_scope
    } do
      assert {:ok, %Connection{state: :connected, listed_at: %DateTime{} = at} = listed} =
               Connections.mark_listed(connected)

      assert DateTime.compare(at, connected.connected_at) != :lt

      assert Map.delete(listed, :listed_at) |> Map.delete(:updated_at) ==
               reload(connected) |> Map.delete(:listed_at) |> Map.delete(:updated_at)

      # Listed already: nothing changes.
      assert Connections.mark_listed(connected) == {:ok, listed}
      assert reload(connected) == listed

      %{scope: other} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(other, adapter, :pending)
      assert Connections.mark_listed(pending) == {:error, :unknown}
      assert reload(pending) == pending

      assert Connections.mark_listed(%Connection{id: Ecto.UUID.generate()}) ==
               {:error, :unknown}

      {:ok, _} = Connections.end_connection(key_scope, connected.public_id)
      ended = reload(connected)
      assert Connections.mark_listed(connected) == {:error, :ended}
      assert reload(connected) == ended
    end

    test "end_connection/2 ends it whatever its organisation's state, and clears its pools there",
         %{scope: scope, adapter: adapter, connected: connected, key_scope: key_scope} do
      {:ok, connection} = Connections.mark_listed(connected)
      %{scope: other} = sign_up_fixture()
      {theirs, _} = connection_fixture(other, adapter, :listed)
      second = connectable_adapter_fixture()
      {_ours, _} = connection_fixture(scope, second.adapter, :listed)

      pool = connected_pool(scope, adapter)
      kept = connected_pool(scope, second.adapter)
      their_pool = connected_pool(other, adapter)

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [scope.organisation.id])

      assert {:ok,
              %Connection{
                state: :ended,
                ended_at: %DateTime{},
                ended_reason: :adapter_reported
              }} = Connections.end_connection(key_scope, connection.public_id)

      assert Repo.get!(Node, pool.id).served_by_id == nil
      assert Repo.get!(Node, kept.id).served_by_id == second.adapter.id
      assert Repo.get!(Node, their_pool.id).served_by_id == adapter.id
      assert reload(theirs).state == :connected

      assert Connections.end_connection(key_scope, connection.public_id) == {:error, :ended}

      assert Connections.end_connection(key_scope(second.access_key), theirs.public_id) ==
               {:error, :unknown}

      assert Connections.end_connection(key_scope, "ac_0000000000000000") == {:error, :unknown}
      assert reload(theirs).state == :connected
    end
  end

  describe "ending from Qory" do
    test "deleting an adapter ends every live connection and clears the pools it served", %{
      scope: scope,
      admin: admin,
      adapter: adapter
    } do
      {connected, _} = connection_fixture(scope, adapter, :listed)
      %{scope: other} = sign_up_fixture()
      {pending, _} = connection_fixture(other, adapter, :pending)
      pool = connected_pool(scope, adapter)

      {:ok, _} = Adapters.delete_adapter(admin, adapter)

      for connection <- [connected, pending] do
        assert %Connection{state: :ended, ended_reason: :integration_deleted} = reload(connection)
      end

      assert Repo.get!(Node, pool.id).served_by_id == nil

      assert %Entry{details: details} =
               Repo.one!(from e in Entry, where: e.action == "adapter.delete")

      assert details["ended_connection_ids"] ==
               Enum.sort([connected.public_id, pending.public_id])

      assert details["unserved_pool_ids"] == [pool.public_id]
    end

    test "an organisation's purge ends its connections first, then deletes them with it", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _} = connection_fixture(scope, adapter, :listed)
      %{scope: other} = sign_up_fixture()
      {theirs, _} = connection_fixture(other, adapter, :listed)
      pool = connected_pool(scope, adapter)

      assert Connections.end_for_organisation(scope.organisation.id) == 1

      assert %Connection{state: :ended, ended_reason: :organisation_deleted} = reload(connection)
      assert Repo.get!(Node, pool.id).served_by_id == nil
      assert reload(theirs).state == :connected
      assert Connections.end_for_organisation(scope.organisation.id) == 0

      # Marked, then purged: no row of it is left.
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      Repo.update_all(
        from(o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -1, :day)]
      )

      assert {:ok, :purged} =
               Deletion.purge_organisation(
                 Scope.for_instance(
                   Repo.get!(Apiary.Organisations.Organisation, scope.organisation.id)
                 )
               )

      assert Repo.get(Connection, connection.id) == nil
      assert reload(theirs).state == :connected
    end
  end

  describe "a pool's adapter" do
    test "is one the organisation is connected to, from the linked return: pending does not count",
         %{scope: scope, adapter: adapter, pair: pair} do
      pool = pool_fixture(scope)
      {connection, nonce} = connection_fixture(scope, adapter, :pending)

      assert Adapters.serving_choices(scope) == []
      assert {:error, changeset} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})
      assert "is invalid" in errors_on(changeset).served_by_id

      assert_raise Postgrex.Error, ~r/nodes_served_by_is_an_adapter/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: [served_by_id: adapter.id])
      end

      # Connected by the linked return, before any listing.
      {:ok, :linked} =
        Connections.complete_return(
          scope,
          connection.public_id,
          return_token(pair.secret, connection.public_id, nonce),
          nonce
        )

      assert %Connection{state: :connected, listed_at: nil} = reload(connection)

      assert [%Node{id: id}] = Adapters.serving_choices(scope)
      assert id == adapter.id

      assert {:ok, %Node{served_by_id: served_by}} =
               Nodes.update_node(scope, pool, %{"served_by_id" => adapter.id})

      assert served_by == adapter.id
      assert [%Node{}] = Adapters.served_pools(scope, adapter)

      assert {:ok, %Node{served_by_id: ^served_by}} =
               Nodes.create_node(scope, %{kind: "pool", name: "spot", served_by_id: adapter.id})

      # Another organisation, not connected, names none.
      %{scope: other} = sign_up_fixture()
      assert Adapters.serving_choices(other) == []
      their_pool = pool_fixture(other)
      assert {:error, _} = Nodes.update_node(other, their_pool, %{served_by_id: adapter.id})
    end
  end

  describe "what people read" do
    test "the organisation's people read its connections, and nobody else", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _} = connection_fixture(scope, adapter, :pending)
      %{scope: member} = member_fixture(scope, :member)
      %{scope: other} = sign_up_fixture()

      for reader <- [scope, member] do
        assert %{} = states = Connections.live_by_adapter(reader)
        assert states[adapter.id].id == connection.id

        assert {:ok, %Connection{id: id}, in_org} =
                 Connections.locate(reader, connection.public_id)

        assert id == connection.id
        assert in_org.organisation.id == scope.organisation.id
      end

      assert Connections.live_by_adapter(other) == %{}
      assert Connections.locate(other, connection.public_id) == :error
      assert Connections.locate(scope, "ac_0000000000000000") == :error
      assert Connections.locate(nil, connection.public_id) == :error
    end
  end

  describe "where the person is not shown the feature" do
    test "nothing is started, taken back, read or offered", %{
      scope: scope,
      adapter: adapter,
      pair: pair
    } do
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      {_connected, _} = connection_fixture(sign_up_fixture().scope, adapter, :listed)

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])

      assert Adapters.connect(scope, adapter) == {:error, :not_found}
      token = return_token(pair.secret, connection.public_id, nonce)

      assert Connections.complete_return(scope, connection.public_id, token, nonce) ==
               {:error, :not_found}

      assert reload(connection) == connection
      assert Connections.locate(scope, connection.public_id) == :error
      assert Connections.live_by_adapter(Access.reload(scope)) == %{}
      assert Adapters.serving_choices(Access.reload(scope)) == []
    end
  end

  describe "the table" do
    defp insert(attrs) do
      now = DateTime.utc_now()

      Repo.insert_all(Connection, [
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            public_id: Apiary.PublicId.generate("ac"),
            state: :pending,
            pass_nonce: :crypto.strong_rand_bytes(16),
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

    test "a connection is to an adapter in use of the instance, and stays with it", %{
      scope: scope,
      admin: admin,
      adapter: adapter
    } do
      base = %{organisation_id: scope.organisation.id, created_by_id: scope.user.id}
      pool = pool_fixture(scope)

      for id <- [pool.id] do
        assert refused(fn -> insert(Map.put(base, :adapter_id, id)) end) ==
                 "adapter_connections_adapter_check"
      end

      {connection, _} = connection_fixture(scope, adapter, :pending)
      %{scope: other} = sign_up_fixture()
      second = adapter_fixture()

      for change <- [
            [organisation_id: other.organisation.id],
            [adapter_id: second.id]
          ] do
        assert refused(fn ->
                 Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
                   set: change
                 )
               end) == "adapter_connections_fixed"
      end

      {:ok, _} = Adapters.delete_adapter(admin, adapter)

      assert refused(fn -> insert(Map.put(base, :adapter_id, adapter.id)) end) ==
               "adapter_connections_adapter_check"
    end

    test "one live connection per organisation and adapter, and its states hold together", %{
      scope: scope,
      adapter: adapter
    } do
      base = %{
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        created_by_id: scope.user.id
      }

      {connection, _} = connection_fixture(scope, adapter, :pending)

      assert refused(fn -> insert(base) end) == "adapter_connections_live_index"

      now = DateTime.utc_now()

      for {attrs, constraint} <- [
            {%{state: :ended, ended_at: now, ended_reason: :adapter_reported, public_id: "ac_x"},
             "adapter_connections_public_id_check"},
            {%{
               state: :ended,
               ended_at: now,
               ended_reason: :adapter_reported,
               pass_nonce: <<0::120>>
             }, "adapter_connections_pass_nonce_check"},
            {%{state: :connected, ended_at: now, ended_reason: :adapter_reported},
             "adapter_connections_state_check"},
            {%{state: :ended, ended_at: now}, "adapter_connections_ended_reason_check"},
            {%{state: :ended, ended_at: now, ended_reason: :adapter_reported, listed_at: now},
             "adapter_connections_listed_check"},
            {%{
               state: :connected,
               connected_at: now,
               listed_at: DateTime.add(now, -1, :second)
             }, "adapter_connections_listed_check"}
          ] do
        assert refused(fn -> insert(Map.merge(base, attrs)) end) == constraint
      end

      for set <- [
            [state: :connected],
            [connected_at: now],
            [listed_at: now],
            [state: :connected, listed_at: now],
            [ended_at: now],
            [ended_reason: :adapter_reported]
          ] do
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(from(c in Connection, where: c.id == ^connection.id), set: set)
        end
      end

      # Ended ones are kept beside the live one.
      Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
        set: [state: :ended, ended_at: now, ended_reason: :adapter_reported]
      )

      ended = %{state: :ended, ended_at: now, ended_reason: :adapter_reported}
      assert {1, _} = insert(Map.merge(base, ended))
      assert {1, _} = insert(base)
      assert refused(fn -> insert(base) end) == "adapter_connections_live_index"
    end
  end

  test "AccessKeys.organisation_in_use?/1 holds to the organisation's state", %{scope: scope} do
    id = scope.organisation.id
    assert AccessKeys.organisation_in_use?(id)
    refute AccessKeys.organisation_in_use?(Ecto.UUID.generate())
    refute AccessKeys.organisation_in_use?("nope")
    refute AccessKeys.organisation_in_use?(nil)

    Edition.put_test_stub(EditionStubs.OutOfUse)
    Process.put(:out_of_use, [id])
    refute AccessKeys.organisation_in_use?(id)
    Process.put(:out_of_use, [])

    {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
    refute AccessKeys.organisation_in_use?(id)
  end
end

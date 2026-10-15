defmodule Apiary.Adapters.DeclareTest do
  # What an adapter declares as it starts (`Apiary.Adapters.declare/2`), how often it
  # checks the source (`sync/1`, `change_sync/2`, `update_sync/3`), what its change feed
  # is told of either, and the connection a person starts (`connect/2`).
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, SigningKey}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.ConnectPass
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @declaration %{
    time: ~U[2026-10-15 12:00:00Z],
    connect_url: "https://tracker-adapter.acme.example/connect",
    default_interval: 900,
    minimum_interval: 300,
    sends_changes: false
  }

  setup do
    %{scope: scope} = sign_up_fixture()
    adapter = adapter_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, adapter)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    %{scope: scope, adapter: adapter, key: key, key_scope: Scope.for_access_key(key)}
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  defp feed(adapter) do
    Repo.all(
      from f in "adapter_feed",
        where: f.adapter_id == type(^adapter.id, :binary_id),
        order_by: f.seq,
        select: {f.seq, f.kind, f.data}
    )
  end

  defp entries(adapter, action) do
    Repo.all(
      from e in Entry,
        where: e.subject_id == ^adapter.id and e.action == ^action,
        order_by: e.inserted_at
    )
  end

  describe "declare/2" do
    test "stores the connect address and the sync, tells the feed the default once, and audits with the key as actor",
         ctx do
      assert {:ok, declared} = Adapters.declare(ctx.key_scope, @declaration)
      assert declared.connect_url == @declaration.connect_url

      assert %Node{
               sync_default_interval: 900,
               sync_minimum_interval: 300,
               sync_sends_changes: false,
               sync_interval: nil
             } = reload(ctx.adapter)

      assert feed(ctx.adapter) == [{1, "sync", %{"interval" => nil}}]

      assert [entry] = entries(ctx.adapter, "adapter.declare")
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}
      assert entry.after["connect_url"] == @declaration.connect_url
      assert entry.after["sync_default_interval"] == 900

      # The same declaration as the adapter starts again changes nothing.
      assert {:ok, _} = Adapters.declare(ctx.key_scope, @declaration)
      assert length(entries(ctx.adapter, "adapter.declare")) == 1
      assert feed(ctx.adapter) == [{1, "sync", %{"interval" => nil}}]

      # Another address is a change, with an entry, and the feed is told nothing.
      other = %{@declaration | connect_url: "https://tracker-adapter.acme.example/v2/connect"}
      assert {:ok, _} = Adapters.declare(ctx.key_scope, other)
      assert [_, second] = entries(ctx.adapter, "adapter.declare")
      assert second.before == %{"connect_url" => @declaration.connect_url}
      assert second.after == %{"connect_url" => other.connect_url}
      assert length(feed(ctx.adapter)) == 1
    end

    test "a later declaration leaves the interval a person set, and tells the feed nothing",
         ctx do
      {:ok, _} = Adapters.declare(ctx.key_scope, @declaration)
      {:ok, _} = Adapters.update_sync(ctx.scope, reload(ctx.adapter), %{"interval" => "300"})
      feed = feed(ctx.adapter)
      assert Enum.map(feed, &elem(&1, 2)) == [%{"interval" => nil}, %{"interval" => 300}]

      # A higher minimum: the interval stays, below it, and the adapter raises it.
      {:ok, declared} =
        Adapters.declare(ctx.key_scope, %{@declaration | minimum_interval: 900})

      assert declared.sync_interval == 300
      assert reload(ctx.adapter).sync_interval == 300

      assert Adapters.sync(declared) == %{
               sends_changes: false,
               interval: 300,
               default: 900,
               minimum: 900,
               choices: [900, 3600]
             }

      # The other kind of checking: the interval stays too.
      {:ok, declared} =
        Adapters.declare(ctx.key_scope, %{
          @declaration
          | sends_changes: true,
            minimum_interval: 900
        })

      assert declared.sync_interval == 300
      assert Adapters.sync(declared).choices == [900, 3600, 21_600, 86_400]

      assert feed(ctx.adapter) == feed

      for entry <- entries(ctx.adapter, "adapter.declare") do
        refute Map.has_key?(entry.after, "sync_interval")
      end
    end

    test "a declaration the changeset refuses stores nothing", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Adapters.declare(ctx.key_scope, %{@declaration | minimum_interval: 1000})

      assert reload(ctx.adapter).connect_url == nil
      assert feed(ctx.adapter) == []
    end

    test "is refused to a node's key, a person, and a deleted adapter's key", ctx do
      %{access_key: node_key} = access_key_fixture(ctx.scope)

      assert Adapters.declare(Scope.for_access_key(node_key), @declaration) ==
               {:error, :not_found}

      assert Adapters.declare(ctx.scope, @declaration) == {:error, :not_found}

      {:ok, _} = Adapters.delete_adapter(ctx.scope, ctx.adapter)
      assert Adapters.declare(ctx.key_scope, @declaration) == {:error, :not_found}
      assert reload(ctx.adapter).connect_url == nil
    end

    test "acts on the key's adapter alone", ctx do
      other = adapter_fixture(ctx.scope)
      {:ok, _} = Adapters.declare(ctx.key_scope, @declaration)
      assert reload(other).connect_url == nil
      assert feed(other) == []
    end
  end

  describe "sync/1" do
    test "has no choices before the adapter declares", ctx do
      assert Adapters.sync(ctx.adapter) == %{
               sends_changes: nil,
               interval: nil,
               default: nil,
               minimum: nil,
               choices: []
             }
    end

    test "offers the intervals of the adapter's kind of checking, at or above its minimum", ctx do
      {:ok, pulls} = Adapters.declare(ctx.key_scope, %{@declaration | minimum_interval: 60})
      assert Adapters.sync(pulls).choices == [60, 300, 900, 3600]

      {:ok, pulls} = Adapters.declare(ctx.key_scope, @declaration)

      assert Adapters.sync(pulls) == %{
               sends_changes: false,
               interval: nil,
               default: 900,
               minimum: 300,
               choices: [300, 900, 3600]
             }

      {:ok, sends} =
        Adapters.declare(ctx.key_scope, %{
          @declaration
          | sends_changes: true,
            default_interval: 21_600,
            minimum_interval: 3600
        })

      assert Adapters.sync(sends).choices == [3600, 21_600, 86_400]
    end
  end

  describe "change_sync/2 and update_sync/3" do
    setup ctx do
      {:ok, adapter} = Adapters.declare(ctx.key_scope, @declaration)
      %{adapter: adapter}
    end

    test "change_sync/2 takes a choice, or empty for the default", ctx do
      assert Adapters.change_sync(ctx.adapter, %{"interval" => "900"}).valid?

      assert Adapters.change_sync(ctx.adapter, %{"sync_interval" => "900"}).changes == %{
               sync_interval: 900
             }

      assert Adapters.change_sync(ctx.adapter, %{"interval" => ""}).valid?
      refute Adapters.change_sync(ctx.adapter, %{"interval" => "60"}).valid?
      refute Adapters.change_sync(ctx.adapter, %{"interval" => "1000"}).valid?
      refute Adapters.change_sync(ctx.adapter, %{"interval" => "soon"}).valid?
    end

    test "sets the interval, appends it to the feed and audits it; the default again appends nil",
         ctx do
      assert {:ok, %Node{sync_interval: 3600}} =
               Adapters.update_sync(ctx.scope, ctx.adapter, %{"interval" => "3600"})

      assert [entry] = entries(ctx.adapter, "adapter.edit")
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.scope.user.id}

      assert {entry.before, entry.after} ==
               {%{"sync_interval" => nil}, %{"sync_interval" => 3600}}

      # The same interval again changes nothing.
      assert {:ok, _} =
               Adapters.update_sync(ctx.scope, reload(ctx.adapter), %{"interval" => 3600})

      assert length(entries(ctx.adapter, "adapter.edit")) == 1

      assert {:ok, %Node{sync_interval: nil}} =
               Adapters.update_sync(ctx.scope, reload(ctx.adapter), %{"interval" => ""})

      assert feed(ctx.adapter) == [
               {1, "sync", %{"interval" => nil}},
               {2, "sync", %{"interval" => 3600}},
               {3, "sync", %{"interval" => nil}}
             ]
    end

    test "refuses an interval outside the choices, and changes nothing", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Adapters.update_sync(ctx.scope, ctx.adapter, %{"interval" => "60"})

      assert reload(ctx.adapter).sync_interval == nil
      assert length(feed(ctx.adapter)) == 1
    end

    test "is an owner's or an admin's, of the adapter's organisation", ctx do
      %{scope: member} = member_fixture(ctx.scope, :member)
      %{scope: admin} = member_fixture(ctx.scope, :admin)

      assert Adapters.update_sync(member, ctx.adapter, %{"interval" => "900"}) ==
               {:error, :forbidden}

      assert {:ok, _} = Adapters.update_sync(admin, ctx.adapter, %{"interval" => "900"})

      %{scope: stranger} = sign_up_fixture()

      assert Adapters.update_sync(stranger, ctx.adapter, %{"interval" => "3600"}) ==
               {:error, :not_found}

      assert reload(ctx.adapter).sync_interval == 900
    end
  end

  describe "connect/2" do
    test "is refused before the adapter declares where to connect", ctx do
      assert Adapters.connect(ctx.scope, ctx.adapter) == {:error, :no_connect_url}
      assert entries(ctx.adapter, "adapter.connect") == []
    end

    test "is refused while the adapter holds no active key", ctx do
      {:ok, adapter} = Adapters.declare(ctx.key_scope, @declaration)
      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      assert Adapters.connect(ctx.scope, adapter) == {:error, :no_key}
      assert entries(ctx.adapter, "adapter.connect") == []
    end

    test "sends the person to the connect address with a fresh pass as state, which no entry holds",
         ctx do
      {:ok, adapter} = Adapters.declare(ctx.key_scope, @declaration)
      assert {:ok, url} = Adapters.connect(ctx.scope, adapter)
      assert "https://tracker-adapter.acme.example/connect?state=" <> pass = url

      assert {:ok, %{adapter_id: adapter_id}} =
               ConnectPass.verify(pass, SigningKey.public_key())

      assert adapter_id == adapter.public_id

      assert {:ok, "https://tracker-adapter.acme.example/connect?state=" <> other} =
               Adapters.connect(ctx.scope, adapter)

      refute other == pass

      for entry <- entries(ctx.adapter, "adapter.connect") do
        refute inspect(Map.from_struct(entry)) =~ pass
      end

      assert length(entries(ctx.adapter, "adapter.connect")) == 2
    end

    test "puts the pass after a query, and before a fragment", ctx do
      for {declared, prefix, suffix} <- [
            {"https://a.example.com/connect?team=acme",
             "https://a.example.com/connect?team=acme&state=", ""},
            {"https://a.example.com/connect?", "https://a.example.com/connect?state=", ""},
            {"https://a.example.com/connect#go", "https://a.example.com/connect?state=", "#go"},
            {"https://a.example.com/c?x=1#go", "https://a.example.com/c?x=1&state=", "#go"},
            {"https://a.example.com", "https://a.example.com?state=", ""}
          ] do
        {:ok, adapter} =
          Adapters.declare(ctx.key_scope, %{@declaration | connect_url: declared})

        assert {:ok, url} = Adapters.connect(ctx.scope, adapter)
        assert String.starts_with?(url, prefix), url
        assert String.ends_with?(url, suffix), url
        pass = url |> String.replace_prefix(prefix, "") |> String.replace_suffix(suffix, "")
        assert {:ok, _} = ConnectPass.verify(pass, SigningKey.public_key())
      end
    end

    test "is an owner's or an admin's", ctx do
      {:ok, adapter} = Adapters.declare(ctx.key_scope, @declaration)
      %{scope: member} = member_fixture(ctx.scope, :member)
      assert Adapters.connect(member, adapter) == {:error, :forbidden}
      %{scope: stranger} = sign_up_fixture()
      assert Adapters.connect(stranger, adapter) == {:error, :not_found}
    end
  end
end

defmodule Apiary.Adapters.SyncTest do
  # What an adapter declares as it starts, and how often it pulls: `declare/2` under the
  # adapter's key, `sync_settings/2` and `update_sync_interval/3` for an instance admin,
  # each change in the instance's trail and, for the interval, in the adapter's change
  # feed; and when the adapter was last seen (`last_seen/2`).
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Edition}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Feed
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @declaration %{
    time: ~U[2026-10-15 12:00:00Z],
    connect_url: "https://tracker-adapter.acme.example/connect",
    default_interval: 3600,
    minimum_interval: 900,
    sends_changes: true
  }

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture(%{name: "Acme tracker"})
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    %{
      scope: scope,
      admin: instance_admin_scope(),
      adapter: adapter,
      key: key,
      key_scope: Scope.for_access_key(key)
    }
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  defp entries(action) do
    Repo.all(
      from e in Entry,
        where: e.action == ^Atom.to_string(action),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp feed(adapter), do: Enum.map(Feed.entries(adapter), &{&1.seq, &1.kind, &1.data})

  describe "declare/2" do
    test "stores the declaration, leaves one entry by the key, and tells the feed the default once",
         %{adapter: adapter, key: key, key_scope: key_scope} do
      assert {:ok, declared} = Adapters.declare(key_scope, @declaration)

      assert %Node{
               connect_url: "https://tracker-adapter.acme.example/connect",
               sync_default_interval: 3600,
               sync_minimum_interval: 900,
               sync_sends_changes: true,
               sync_interval: nil
             } = reload(adapter)

      assert declared.sync_default_interval == 3600

      assert [entry] = entries(:"adapter.declare")
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
      assert {entry.subject_kind, entry.subject_id} == {"node", adapter.id}
      assert entry.organisation_id == Edition.instance_organisation_id()

      assert entry.after == %{
               "connect_url" => "https://tracker-adapter.acme.example/connect",
               "sync_default_interval" => 3600,
               "sync_minimum_interval" => 900,
               "sync_sends_changes" => true
             }

      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]

      # The same declaration again changes nothing: no entry, no feed entry.
      assert {:ok, _} = Adapters.declare(key_scope, @declaration)
      assert length(entries(:"adapter.declare")) == 1
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]

      # A changed one leaves its entry with what changed alone, and tells the feed nothing.
      assert {:ok, _} =
               Adapters.declare(key_scope, %{@declaration | connect_url: "https://b.example/c"})

      assert [_, second] = entries(:"adapter.declare")
      assert second.before == %{"connect_url" => "https://tracker-adapter.acme.example/connect"}
      assert second.after == %{"connect_url" => "https://b.example/c"}
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]
    end

    test "keeps the interval an instance admin chose, even below a later minimum",
         %{admin: admin, adapter: adapter, key_scope: key_scope} do
      {:ok, _} = Adapters.declare(key_scope, @declaration)
      {:ok, _} = Adapters.update_sync_interval(admin, adapter, %{sync_interval: 900})

      {:ok, _} =
        Adapters.declare(key_scope, %{
          @declaration
          | minimum_interval: 1800,
            default_interval: 7200
        })

      assert %Node{sync_interval: 900, sync_minimum_interval: 1800} = reload(adapter)

      assert {:ok,
              %{interval: 900, minimum: 1800, choices: [1800, 3600, 7200, 21_600, 43_200, 86_400]}} =
               Adapters.sync_settings(admin, adapter)
    end

    test "is refused to a key of another kind, to a person, and for a deleted adapter",
         %{scope: scope, admin: admin, adapter: adapter, key_scope: key_scope} do
      %{access_key: node_key} = node_key_fixture(scope, node_fixture(scope))
      {:ok, node_key} = AccessKeys.fetch_for_verification(node_key.key_id)

      assert Adapters.declare(Scope.for_access_key(node_key), @declaration) ==
               {:error, :not_found}

      assert {:error, _} = Adapters.declare(admin, @declaration)
      assert {:error, _} = Adapters.declare(scope, @declaration)

      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert Adapters.declare(key_scope, @declaration) == {:error, :not_found}

      assert %Node{connect_url: "https://tracker.example.com/connect", sync_default_interval: nil} =
               reload(adapter)

      assert entries(:"adapter.declare") == []
      assert Feed.entries(adapter) == []
    end

    test "the database refuses what the contract refuses, whatever the caller" do
      adapter = %Node{kind: :adapter}

      for {attrs, field} <- [
            {%{sync_default_interval: 59}, :sync_default_interval},
            {%{sync_default_interval: 86_401}, :sync_default_interval},
            {%{sync_minimum_interval: 59}, :sync_minimum_interval},
            {%{sync_minimum_interval: 3601}, :sync_minimum_interval},
            {%{sync_sends_changes: nil}, :sync_sends_changes},
            {%{connect_url: "http://a.example/c"}, :connect_url}
          ] do
        changeset =
          Node.declaration_changeset(
            adapter,
            Map.merge(
              %{
                connect_url: "https://a.example/c",
                sync_default_interval: 3600,
                sync_minimum_interval: 900,
                sync_sends_changes: false
              },
              attrs
            )
          )

        refute changeset.valid?, inspect(attrs)
        assert Keyword.has_key?(changeset.errors, field), inspect(attrs)
      end
    end
  end

  describe "sync_settings/2" do
    test "before the declaration: nothing declared, no choices", %{admin: admin, adapter: adapter} do
      assert Adapters.sync_settings(admin, adapter) ==
               {:ok,
                %{interval: nil, default: nil, minimum: nil, sends_changes: nil, choices: []}}
    end

    test "after it: the declared default and minimum, the choice, and the choices from the minimum",
         %{admin: admin, adapter: adapter, key_scope: key_scope} do
      {:ok, _} = Adapters.declare(key_scope, @declaration)

      assert Adapters.sync_settings(admin, adapter) ==
               {:ok,
                %{
                  interval: nil,
                  default: 3600,
                  minimum: 900,
                  sends_changes: true,
                  choices: [900, 1800, 3600, 7200, 21_600, 43_200, 86_400]
                }}

      # A minute's minimum offers every step; a default off the ladder is offered too.
      {:ok, _} =
        Adapters.declare(key_scope, %{@declaration | minimum_interval: 60, default_interval: 120})

      assert {:ok, %{choices: [60, 120, 300, 600, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400]}} =
               Adapters.sync_settings(admin, adapter)

      # A day's minimum offers a day alone.
      {:ok, _} =
        Adapters.declare(key_scope, %{
          @declaration
          | minimum_interval: 86_400,
            default_interval: 86_400
        })

      assert {:ok, %{choices: [86_400]}} = Adapters.sync_settings(admin, adapter)
    end

    test "only to an instance admin, of an adapter in use",
         %{scope: scope, admin: admin, adapter: adapter, key_scope: key_scope} do
      assert Adapters.sync_settings(scope, adapter) == {:error, :forbidden}
      assert Adapters.sync_settings(key_scope, adapter) == {:error, :forbidden}

      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert Adapters.sync_settings(admin, adapter) == {:error, :not_found}
    end
  end

  describe "update_sync_interval/3" do
    setup %{key_scope: key_scope} do
      {:ok, _} = Adapters.declare(key_scope, @declaration)
      :ok
    end

    test "an instance admin sets one of the choices: one entry and one feed entry per change",
         %{admin: admin, adapter: adapter} do
      assert {:ok, %Node{sync_interval: 7200}} =
               Adapters.update_sync_interval(admin, adapter, %{sync_interval: 7200})

      assert reload(adapter).sync_interval == 7200

      assert [entry] = entries(:"adapter.set_interval")
      assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}
      assert {entry.subject_kind, entry.subject_id} == {"node", adapter.id}
      assert entry.organisation_id == Edition.instance_organisation_id()
      assert entry.before == %{"sync_interval" => nil}
      assert entry.after == %{"sync_interval" => 7200}

      # From a form: a decimal string, and the empty value for the declared default.
      assert {:ok, %Node{sync_interval: 900}} =
               Adapters.update_sync_interval(admin, adapter, %{"sync_interval" => "900"})

      assert {:ok, %Node{sync_interval: nil}} =
               Adapters.update_sync_interval(admin, adapter, %{"sync_interval" => ""})

      # The same value again changes nothing.
      assert {:ok, %Node{sync_interval: nil}} =
               Adapters.update_sync_interval(admin, adapter, %{sync_interval: nil})

      assert [_, _, third] = entries(:"adapter.set_interval")
      assert third.before == %{"sync_interval" => 900}
      assert third.after == %{"sync_interval" => nil}

      assert feed(adapter) == [
               {1, "sync", %{"interval" => nil}},
               {2, "sync", %{"interval" => 7200}},
               {3, "sync", %{"interval" => 900}},
               {4, "sync", %{"interval" => nil}}
             ]
    end

    test "a value that is not one of the choices is refused, and changes nothing",
         %{admin: admin, adapter: adapter} do
      for value <- [600, 60, 1000, 86_401, 0, -1, "abc", "3600.0", 3600.5, [3600]] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Adapters.update_sync_interval(admin, adapter, %{sync_interval: value})

        assert Keyword.has_key?(changeset.errors, :sync_interval), inspect(value)
      end

      assert reload(adapter).sync_interval == nil
      assert entries(:"adapter.set_interval") == []
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]
    end

    test "is refused to anyone but an instance admin, and for a deleted adapter",
         %{scope: scope, admin: admin, adapter: adapter, key_scope: key_scope} do
      %{scope: member} = member_fixture(scope)

      for asker <- [scope, member, key_scope] do
        assert Adapters.update_sync_interval(asker, adapter, %{sync_interval: 3600}) ==
                 {:error, :forbidden}
      end

      {:ok, _} = Adapters.delete_adapter(admin, adapter)

      assert Adapters.update_sync_interval(admin, adapter, %{sync_interval: 3600}) ==
               {:error, :not_found}

      assert entries(:"adapter.set_interval") == []
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]
    end
  end

  test "update_sync_interval/3 before the adapter declared is refused :not_declared",
       %{admin: admin, adapter: adapter} do
    assert Adapters.update_sync_interval(admin, adapter, %{sync_interval: 3600}) ==
             {:error, :not_declared}

    assert reload(adapter).sync_interval == nil
    assert entries(:"adapter.set_interval") == []
    assert Feed.entries(adapter) == []
  end

  describe "last_seen/2" do
    test "the latest use of the adapter's keys, revoked ones included, or nil",
         %{scope: scope, admin: admin, adapter: adapter, key: key} do
      other = adapter_fixture(name: "Acme chat")

      assert Adapters.last_seen(admin, adapter) == nil
      assert Adapters.last_seen(admin, [adapter, other]) == %{}

      %{access_key: second} = enrolled_key_fixture(admin, adapter)
      earlier = ~U[2026-10-15 10:00:00.000000Z]
      later = ~U[2026-10-15 11:00:00.000000Z]
      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [last_used_at: later])

      Repo.update_all(from(k in AccessKey, where: k.id == ^second.id),
        set: [last_used_at: earlier]
      )

      {:ok, _} = Adapters.revoke_key(admin, Repo.get!(AccessKey, key.id))

      assert Adapters.last_seen(admin, adapter) == later
      assert Adapters.last_seen(admin, [adapter, other]) == %{adapter.id => later}

      # Whoever may read the instance's adapters reads it; a member of an organisation where
      # they are shown, too.
      assert Adapters.last_seen(scope, adapter) == later
      assert Adapters.last_seen(%Scope{}, adapter) == nil
      assert Adapters.last_seen(%Scope{}, [adapter]) == %{}
    end
  end
end

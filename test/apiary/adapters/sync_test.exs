defmodule Apiary.Adapters.SyncTest do
  # What an adapter declares as it starts, and how often it pulls: `declare/2` under the
  # adapter's key, its setup_url among what it stores, `sync_settings/2` and
  # `update_sync_interval/3` for an instance admin, each change in the instance's trail
  # and, for the interval, in the adapter's change feed; and when the adapter was last
  # seen (`last_seen/2`).
  use Apiary.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures

  import Apiary.DescriptionFixtures,
    only: [
      contract_description: 0,
      contract_description: 1,
      read_description: 0,
      read_description: 1
    ]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Edition}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collections, Feed}
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @base %{
    time: ~U[2026-10-15 12:00:00Z],
    connect_url: "https://tracker-adapter.acme.example/connect",
    default_interval: 3600,
    minimum_interval: 900,
    sends_changes: true
  }

  # A declaration as `Apiary.Adapters.Wire.declaration/1` reads one, with the contract's
  # description of an example tracker.
  defp declaration, do: Map.put(@base, :description, read_description())

  setup do
    %{scope: scope} = sign_up_fixture()

    %{adapter: adapter, access_key: key} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

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
      assert {:ok, declared} = Adapters.declare(key_scope, declaration())

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
      assert {:ok, _} = Adapters.declare(key_scope, declaration())
      assert length(entries(:"adapter.declare")) == 1
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]

      # A changed one leaves its entry with what changed alone, and tells the feed nothing.
      assert {:ok, _} =
               Adapters.declare(key_scope, %{declaration() | connect_url: "https://b.example/c"})

      assert [_, second] = entries(:"adapter.declare")
      assert second.before == %{"connect_url" => "https://tracker-adapter.acme.example/connect"}
      assert second.after == %{"connect_url" => "https://b.example/c"}
      assert feed(adapter) == [{1, "sync", %{"interval" => nil}}]
    end

    test "stores the setup_url declared; a declaration without one clears it, each change in the trail",
         %{adapter: adapter, key_scope: key_scope} do
      url = "https://tracker-adapter.acme.example/setup?site=main"

      assert {:ok, %Node{setup_url: ^url}} =
               Adapters.declare(key_scope, Map.put(declaration(), :setup_url, url))

      assert reload(adapter).setup_url == url
      assert [first] = entries(:"adapter.declare")
      assert first.after["setup_url"] == url

      # Set up at its source, the adapter declares no setup_url: it is cleared.
      assert {:ok, %Node{setup_url: nil}} =
               Adapters.declare(key_scope, Map.put(declaration(), :setup_url, nil))

      assert reload(adapter).setup_url == nil
      assert [_, second] = entries(:"adapter.declare")
      assert second.before == %{"setup_url" => url}
      assert second.after == %{"setup_url" => nil}

      # A declaration with no setup_url member at all clears it too.
      assert {:ok, _} = Adapters.declare(key_scope, Map.put(declaration(), :setup_url, url))
      assert reload(adapter).setup_url == url
      assert {:ok, _} = Adapters.declare(key_scope, declaration())
      assert reload(adapter).setup_url == nil
      assert length(entries(:"adapter.declare")) == 4
    end

    test "stores the call_url declared with the instance id it is signed for; a declaration without one clears both",
         %{adapter: adapter, key_scope: key_scope} do
      url = "https://acme-tracker.qory.example/calls/"
      called = &Map.merge(declaration(), %{call_url: url, instance_id: &1})

      assert {:ok, %Node{call_url: ^url, call_instance_id: "instance-a"}} =
               Adapters.declare(key_scope, called.("instance-a"))

      assert {reload(adapter).call_url, reload(adapter).call_instance_id} == {url, "instance-a"}
      assert [first] = entries(:"adapter.declare")
      assert first.after["call_url"] == url
      refute Map.has_key?(first.after, "call_instance_id")

      # A start under another instance id keeps the address and takes the id, with no
      # entry: the trail has the address alone.
      assert {:ok, _} = Adapters.declare(key_scope, called.("instance-b"))
      assert reload(adapter).call_instance_id == "instance-b"
      assert length(entries(:"adapter.declare")) == 1

      # A declaration with no call_url clears both, whatever instance id it came with.
      assert {:ok, %Node{call_url: nil, call_instance_id: nil}} =
               Adapters.declare(key_scope, Map.put(declaration(), :instance_id, "instance-b"))

      assert [_, second] = entries(:"adapter.declare")
      assert second.before == %{"call_url" => url}
      assert second.after == %{"call_url" => nil}

      # A call_url without an instance id is refused, and nothing changes.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Adapters.declare(key_scope, Map.put(declaration(), :call_url, url))

      assert Keyword.has_key?(changeset.errors, :call_instance_id)
      assert reload(adapter).call_url == nil
      assert length(entries(:"adapter.declare")) == 2
    end

    test "the database holds a call_url to an https address whose path ends with /, with its instance id, on adapters alone",
         %{scope: scope, adapter: adapter} do
      at = from(n in Node, where: n.id == ^adapter.id)

      for url <- [
            "https://tracker.example.com/",
            "https://tracker.example.com:8443/calls/v1/",
            "https://tracker.example.com/" <> String.duplicate("a", 2048 - 29) <> "/"
          ] do
        assert {1, _} = Repo.update_all(at, set: [call_url: url, call_instance_id: "a.b_c-1"])
      end

      assert {1, _} = Repo.update_all(at, set: [call_url: nil, call_instance_id: nil])

      for {url, id} <- [
            {"https://tracker.example.com", "a"},
            {"https://tracker.example.com/calls", "a"},
            {"https://tracker.example.com/calls/?x=/", "a"},
            {"https://tracker.example.com/calls/#x/", "a"},
            {"http://tracker.example.com/calls/", "a"},
            {"https://user@tracker.example.com/calls/", "a"},
            {"https://tracker.example.com/ca lls/", "a"},
            {"https://tracker.example.com/" <> String.duplicate("a", 2048 - 28) <> "/", "a"},
            {"https://tracker.example.com/calls/", nil},
            {nil, "a"},
            {"https://tracker.example.com/calls/", "-a"},
            {"https://tracker.example.com/calls/", "a b"},
            {"https://tracker.example.com/calls/", String.duplicate("a", 65)}
          ] do
        assert_raise Postgrex.Error, ~r/nodes_call_url_check/, fn ->
          Repo.update_all(at, set: [call_url: url, call_instance_id: id])
        end
      end

      node = Apiary.NodesFixtures.node_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_call_url_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id),
          set: [call_url: "https://tracker.example.com/calls/", call_instance_id: "a"]
        )
      end
    end

    test "the database holds a setup_url to an https address with no fragment, on adapters alone",
         %{scope: scope, adapter: adapter} do
      at = from(n in Node, where: n.id == ^adapter.id)

      for url <- [
            "https://tracker.example.com",
            "https://tracker.example.com:8443/setup?site=main",
            "https://tracker.example.com/" <> String.duplicate("a", 2048 - 28)
          ] do
        assert {1, _} = Repo.update_all(at, set: [setup_url: url])
      end

      for url <- [
            "https://tracker.example.com/setup#start",
            "https://tracker.example.com#",
            "http://tracker.example.com/setup",
            "https://user@tracker.example.com/setup",
            "https://tracker.example.com/se tup",
            "https://tracker.example.com/" <> String.duplicate("a", 2048 - 27)
          ] do
        assert_raise Postgrex.Error, ~r/nodes_setup_url_check/, fn ->
          Repo.update_all(at, set: [setup_url: url])
        end
      end

      node = Apiary.NodesFixtures.node_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_setup_url_check/, fn ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id),
          set: [setup_url: "https://tracker.example.com/setup"]
        )
      end
    end

    test "stores the source role's words and items at each start, the latest start's alone",
         %{adapter: adapter, key_scope: key_scope} do
      words = fn node ->
        node = reload(node)

        {node.item_noun_one, node.item_noun_other, node.items, node.collection_noun_one,
         node.collection_noun_other}
      end

      # Before its first start, the defaults: no words, and items.
      assert words.(adapter) == {nil, nil, true, nil, nil}

      assert {:ok, _} = Adapters.declare(key_scope, declaration())
      assert words.(adapter) == {"issue", "issues", true, "project", "projects"}
      assert Adapters.item_noun(reload(adapter)) == %{one: "issue", other: "issues"}
      assert Adapters.collection_noun(reload(adapter)) == %{one: "project", other: "projects"}

      # The next start replaces them, whatever it says.
      tasks_and_boards =
        Apiary.DescriptionFixtures.contract_description()
        |> put_in(["roles", "source", "item_noun"], %{"one" => "task", "other" => "tasks"})
        |> put_in(["roles", "source", "collection_noun"], %{"one" => "board", "other" => "boards"})

      for {name, description, expected} <- [
            {"tasks and boards", tasks_and_boards, {"task", "tasks", true, "board", "boards"}},
            {"example-projects.json", "example-projects.json",
             {nil, nil, false, "project", "projects"}},
            {"acme-tracker.json", "acme-tracker.json", {nil, nil, true, nil, nil}},
            {"example-tracker.json", "example-tracker.json",
             {"issue", "issues", true, "project", "projects"}}
          ] do
        assert {:ok, _} =
                 Adapters.declare(key_scope, %{
                   declaration()
                   | description: read_description(description)
                 })

        assert words.(adapter) == expected, name
      end

      # None of it is in the trail's entries: the first start's is the only one.
      assert [entry] = entries(:"adapter.declare")
      refute Enum.any?(Map.keys(entry.after), &String.contains?(&1, "noun"))
      refute Map.has_key?(entry.after, "items")
    end

    test "the database holds the words for collections to the contract's, beside no items too",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      {:ok, _} =
        Adapters.declare(key_scope, %{
          declaration()
          | description: read_description("example-projects.json")
        })

      set = fn node, fields ->
        Repo.update_all(from(n in Node, where: n.id == ^node.id), set: fields)
      end

      assert {1, _} =
               set.(adapter, collection_noun_one: "work board", collection_noun_other: "works")

      # Never "work item" or "work items", with a space or a hyphen, as for its items.
      for fields <- [
            [collection_noun_one: "work item"],
            [collection_noun_other: "work-items"],
            [collection_noun_one: "work-item"],
            [collection_noun_other: "work items"],
            [collection_noun_one: "Project"],
            [collection_noun_other: "code  bases"],
            [collection_noun_one: "-project"],
            [collection_noun_one: String.duplicate("z", 33)],
            [collection_noun_one: ""],
            [collection_noun_one: nil]
          ] do
        assert_raise Postgrex.Error, ~r/nodes_collection_noun_check/, fn ->
          set.(adapter, fields)
        end
      end

      pool = pool_fixture(scope)

      assert_raise Postgrex.Error, ~r/nodes_collection_noun_check/, fn ->
        set.(pool, collection_noun_one: "project", collection_noun_other: "projects")
      end
    end

    test "stores the source role's access line at each start, and only an adapter holds one",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      line =
        "In Example Tracker, open Settings, then Connected adapters, to change which " <>
          "projects the adapter reads."

      # Before its first start, none.
      assert reload(adapter).source_access == nil

      assert {:ok, declared} = Adapters.declare(key_scope, declaration())
      assert declared.source_access == line
      assert reload(adapter).source_access == line

      # The next start replaces it, whatever it says; no source role, no line.
      boards =
        Apiary.DescriptionFixtures.contract_description()
        |> put_in(["roles", "source", "access"], "Ask an owner to change the boards.")

      for {name, description, expected} <- [
            {"another line", boards, "Ask an owner to change the boards."},
            {"example-projects.json", "example-projects.json", line},
            {"acme-tracker.json", "acme-tracker.json", nil},
            {"example-tracker.json", "example-tracker.json", line}
          ] do
        assert {:ok, _} =
                 Adapters.declare(key_scope, %{
                   declaration()
                   | description: read_description(description)
                 })

        assert reload(adapter).source_access == expected, name
      end

      # It is no part of the trail's entries.
      assert [entry] = entries(:"adapter.declare")
      refute Map.has_key?(entry.after, "source_access")

      # Only an adapter holds one (`nodes_source_access_check`).
      for other <- [pool_fixture(scope), node_fixture(scope)] do
        assert_raise Postgrex.Error, ~r/nodes_source_access_check/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^other.id), set: [source_access: line])
        end
      end
    end

    test "stores the source role's guide at each start, and only an adapter holds one",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      guided = contract_description("example-source-guide.json")
      guide = guided["roles"]["source"]["guide"]

      # Before its first start, none.
      assert reload(adapter).source_guide == nil

      assert {:ok, declared} =
               Adapters.declare(key_scope, %{
                 declaration()
                 | description: read_description(guided)
               })

      assert declared.source_guide == guide
      assert reload(adapter).source_guide == guide

      assert Adapters.guide(reload(adapter), :setup) == %{
               before: "You need the administrator role in Example Tracker.",
               steps: guide["setup"]["steps"],
               after: "The adapter is registered with Example Tracker."
             }

      assert Adapters.guide(reload(adapter), :connect) == %{
               before: nil,
               steps: guide["connect"]["steps"],
               after: nil
             }

      # The next start replaces it; a description with no guide leaves none.
      assert {:ok, _} = Adapters.declare(key_scope, declaration())
      assert reload(adapter).source_guide == nil
      assert Adapters.guide(reload(adapter), :setup) == nil

      # Only an adapter holds one (`nodes_source_guide_check`).
      for other <- [pool_fixture(scope), node_fixture(scope)] do
        assert_raise Postgrex.Error, ~r/nodes_source_guide_check/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^other.id), set: [source_guide: guide])
        end
      end
    end

    test "stores whether the adapter's collections have targets at each start, on an adapter alone",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      # Before its first start, nil.
      assert reload(adapter).targets == nil

      # A description that says nothing: false.
      assert {:ok, declared} = Adapters.declare(key_scope, declaration())
      assert declared.targets == false
      assert reload(adapter).targets == false

      # A description with `targets: true`, which the contract's check accepts.
      targeted = read_description("example-source-targets.json")

      assert {:ok, declared} =
               Adapters.declare(key_scope, %{declaration() | description: targeted})

      assert declared.targets == true
      assert reload(adapter).targets == true

      # The next start replaces it.
      assert {:ok, _} = Adapters.declare(key_scope, declaration())
      assert reload(adapter).targets == false

      # It is no part of the trail's entries.
      for entry <- entries(:"adapter.declare") do
        refute Map.has_key?(entry.after, "targets")
      end

      # Only an adapter holds one (`nodes_targets_check`).
      for other <- [pool_fixture(scope), node_fixture(scope)] do
        assert reload(other).targets == nil

        assert_raise Postgrex.Error, ~r/nodes_targets_check/, fn ->
          Repo.update_all(from(n in Node, where: n.id == ^other.id), set: [targets: false])
        end
      end
    end

    test "a start that changes the access line or a word tells each connected organisation once",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      %{scope: other} = sign_up_fixture()
      %{scope: unconnected} = sign_up_fixture()
      {listed, _nonce} = connection_fixture(scope, adapter, :listed)
      {pending, _nonce} = connection_fixture(other, adapter, :pending)
      {:ok, _} = Adapters.declare(key_scope, declaration())

      for subscriber <- [scope, other, unconnected],
          do: assert(Collections.subscribe(subscriber) == :ok)

      start = fn description ->
        assert {:ok, _} = Adapters.declare(key_scope, %{declaration() | description: description})

        receive_all = fn receive_all, acc ->
          receive do
            {kind, _payload} = message when kind in [:connection_changed, :collections_changed] ->
              receive_all.(receive_all, [message | acc])
          after
            0 -> Enum.sort(acc)
          end
        end

        receive_all.(receive_all, [])
      end

      told =
        Enum.sort(
          for connection <- [listed, pending],
              do: {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
        )

      # Each start changes one field of the source role from the start before it.
      put = &put_in(&1, ["roles", "source", &2], &3)
      access = put.(contract_description(), "access", "Ask an owner to change the boards.")
      tasks = put.(access, "item_noun", %{"one" => "task", "other" => "tasks"})
      boards = put.(tasks, "collection_noun", %{"one" => "board", "other" => "boards"})

      # Only the access line, then only the words for the items, then only those for the
      # collections: each organisation with a connection hears once, the other none.
      assert start.(read_description(access)) == told
      assert start.(read_description(tasks)) == told
      assert start.(read_description(boards)) == told

      # The same start again, and one that changes its connect address alone: none.
      assert start.(read_description(boards)) == []

      assert {:ok, _} =
               Adapters.declare(key_scope, %{
                 declaration()
                 | connect_url: "https://b.example/c",
                   description: read_description(boards)
               })

      refute_received {:connection_changed, _payload}
    end

    test "a start whose connections the database fails to read answers as stored, and logs it",
         %{scope: scope, adapter: adapter, key_scope: key_scope} do
      {_connection, _nonce} = connection_fixture(scope, adapter, :listed)
      {:ok, _} = Adapters.declare(key_scope, declaration())
      assert Collections.subscribe(scope) == :ok

      line = "Ask an owner to change the boards."

      description =
        contract_description()
        |> put_in(["roles", "source", "access"], line)
        |> read_description()

      for failure <- [
            %DBConnection.ConnectionError{message: "connection closed"},
            %Postgrex.Error{postgres: %{code: :query_canceled, message: "a detail of the row"}}
          ] do
        {1, _} =
          Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [source_access: nil])

        log =
          capture_log(fn ->
            assert {:ok, %Node{source_access: ^line}} =
                     Adapters.declare(key_scope, %{declaration() | description: description},
                       connections: fn _adapter -> raise failure end
                     )
          end)

        assert reload(adapter).source_access == line
        assert log =~ "could not tell the organisations connected to adapter #{adapter.public_id}"
        # The error's kind alone: never its message.
        refute log =~ "connection closed"
        refute log =~ "a detail of the row"
        refute_received {:connection_changed, _payload}
      end

      # Anything else is no failure of the database, and is not caught.
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [source_access: nil])

      assert_raise RuntimeError, fn ->
        Adapters.declare(key_scope, %{declaration() | description: description},
          connections: fn _adapter -> raise "not a database failure" end
        )
      end
    end

    test "keeps the interval an instance admin chose, even below a later minimum",
         %{admin: admin, adapter: adapter, key_scope: key_scope} do
      {:ok, _} = Adapters.declare(key_scope, declaration())
      {:ok, _} = Adapters.update_sync_interval(admin, adapter, %{sync_interval: 900})

      {:ok, _} =
        Adapters.declare(key_scope, %{
          declaration()
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

      assert Adapters.declare(Scope.for_access_key(node_key), declaration()) ==
               {:error, :not_found}

      assert {:error, _} = Adapters.declare(admin, declaration())
      assert {:error, _} = Adapters.declare(scope, declaration())

      {:ok, _} = Adapters.delete_adapter(admin, adapter)
      assert Adapters.declare(key_scope, declaration()) == {:error, :not_found}

      assert %Node{connect_url: "https://tracker.example.com/connect", sync_default_interval: nil} =
               reload(adapter)

      assert entries(:"adapter.declare") == []
      assert Feed.entries(adapter) == []
    end

    test "the changeset refuses what the contract refuses" do
      adapter = %Node{kind: :adapter}

      for {attrs, field} <- [
            {%{sync_default_interval: 59}, :sync_default_interval},
            {%{sync_default_interval: 86_401}, :sync_default_interval},
            {%{sync_minimum_interval: 59}, :sync_minimum_interval},
            {%{sync_minimum_interval: 3601}, :sync_minimum_interval},
            {%{sync_sends_changes: nil}, :sync_sends_changes},
            {%{connect_url: "http://a.example/c"}, :connect_url},
            {%{setup_url: "http://a.example/setup"}, :setup_url},
            {%{setup_url: "https://a.example/setup#start"}, :setup_url},
            {%{setup_url: "https://a.example/" <> String.duplicate("a", 2048)}, :setup_url},
            {%{call_url: "http://a.example/calls/", call_instance_id: "a"}, :call_url},
            {%{call_url: "https://a.example/calls", call_instance_id: "a"}, :call_url},
            {%{call_url: "https://a.example/calls/?x=/", call_instance_id: "a"}, :call_url},
            {%{
               call_url: "https://a.example/" <> String.duplicate("a", 2048) <> "/",
               call_instance_id: "a"
             }, :call_url},
            {%{call_url: "https://a.example/calls/"}, :call_instance_id},
            {%{call_instance_id: "a"}, :call_url},
            {%{call_url: "https://a.example/calls/", call_instance_id: "-a"}, :call_instance_id}
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
      {:ok, _} = Adapters.declare(key_scope, declaration())

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
        Adapters.declare(key_scope, %{declaration() | minimum_interval: 60, default_interval: 120})

      assert {:ok, %{choices: [60, 120, 300, 600, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400]}} =
               Adapters.sync_settings(admin, adapter)

      # A day's minimum offers a day alone.
      {:ok, _} =
        Adapters.declare(key_scope, %{
          declaration()
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
      {:ok, _} = Adapters.declare(key_scope, declaration())
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
      other = adapter_fixture(name: unique_adapter_name("Acme chat"))

      assert Adapters.last_seen(admin, adapter) == {:ok, nil}
      assert Adapters.last_seen(admin, [adapter, other]) == {:ok, %{}}

      %{access_key: second} = enrolled_key_fixture(admin, adapter)
      earlier = ~U[2026-10-15 10:00:00.000000Z]
      later = ~U[2026-10-15 11:00:00.000000Z]
      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [last_used_at: later])

      Repo.update_all(from(k in AccessKey, where: k.id == ^second.id),
        set: [last_used_at: earlier]
      )

      {:ok, _} = Adapters.revoke_key(admin, Repo.get!(AccessKey, key.id))

      assert Adapters.last_seen(admin, adapter) == {:ok, later}
      assert Adapters.last_seen(admin, [adapter, other]) == {:ok, %{adapter.id => later}}

      # An instance admin reads it; a member of an organisation where adapters are shown
      # does not.
      assert Adapters.last_seen(scope, adapter) == {:error, :forbidden}
      assert Adapters.last_seen(scope, [adapter]) == {:error, :forbidden}
      assert Adapters.last_seen(%Scope{}, adapter) == {:error, :forbidden}
      assert Adapters.last_seen(%Scope{}, [adapter]) == {:error, :forbidden}
    end

    test "is refused to an adapter's key", %{adapter: adapter, key_scope: key_scope} do
      assert Adapters.last_seen(key_scope, adapter) == {:error, :forbidden}
      assert Adapters.last_seen(key_scope, [adapter]) == {:error, :forbidden}
    end
  end
end

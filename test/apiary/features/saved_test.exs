defmodule Apiary.Features.SavedTest.Down do
  @moduledoc false
  # `Apiary.Features.Saved` for the cache, but each read raises a connection error while
  # the database is down: `:persistent_term` `{__MODULE__, :down}` set to true. A boot that
  # succeeds sends `{__MODULE__, :booted}` to the process in `{__MODULE__, :test}`.

  alias Apiary.Features.Saved

  def boot do
    read(fn ->
      result = Saved.boot()
      send(:persistent_term.get({__MODULE__, :test}), {__MODULE__, :booted})
      result
    end)
  end

  def version, do: read(&Saved.version/0)
  def refresh, do: read(&Saved.refresh/0)

  defp read(fun) do
    if :persistent_term.get({__MODULE__, :down}, false),
      do: raise(DBConnection.ConnectionError, "connection refused"),
      else: fun.()
  end
end

defmodule Apiary.Features.SavedTest do
  @moduledoc """
  The features an instance admin saves (`Apiary.Features.Saved`): where the list in force
  comes from, the needs and the locks, the save and its refusals, the instance's trail,
  each node's copy (`Apiary.Features.Cache`), and the work at boot that no longer depends
  on the list.
  """
  # Not async: the features, the variable's value and the node's copy are the whole node's.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Features
  alias Apiary.Features.{Cache, Saved}
  alias Apiary.Features.Saved.Row

  @moduletag :feature_sets

  setup do
    for key <- [
          :features,
          :features_setting,
          :installed_adapters,
          :installed_nodes,
          :registry_setting
        ] do
      before = Application.fetch_env(:apiary, key)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end)
    end

    Application.put_env(:apiary, :features_setting, nil)
    Application.put_env(:apiary, :installed_adapters, [])
    Application.put_env(:apiary, :installed_nodes, %{pool: nil, gateway: nil, url: nil})
    Application.put_env(:apiary, :registry_setting, nil)

    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    %{scope: scope}
  end

  defp defaults, do: Features.all() -- Features.opt_in()

  defp entries,
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "instance.features_save",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp row, do: Repo.get(Row, true)

  # Saves `names` as the saved list, as a save on another node would, without this node's
  # copy or a broadcast: with every feature of the release seen, or the ones of `seen`,
  # as a release that had only those saved it.
  defp store!(names, seen \\ Features.all()) do
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    {1, _rows} =
      Repo.update_all(from(r in Row, where: r.id == true),
        set: [features: names, features_seen: Enum.map(seen, &to_string/1)],
        inc: [features_version: 1]
      )

    :ok
  end

  defp names(features), do: Enum.map(features, &to_string/1)

  describe "close/2 and preview/2" do
    test "turning a feature on turns on what it needs, directly or through another" do
      current = [:observability, :security]
      wanted = current ++ [:workflow_model]

      assert Saved.close(current, wanted) ==
               [:observability, :security, :secrets, :factory, :workflow_model]

      assert Saved.preview(current, wanted) == [
               %{feature: :workflow_model, turns: :on, with: [:secrets, :factory]}
             ]
    end

    test "turning a feature off turns off what needs it" do
      current = defaults()
      wanted = current -- [:secrets]

      assert Saved.close(current, wanted) ==
               current -- [:secrets, :factory, :workflow_model, :organisation_variables]

      assert Saved.preview(current, wanted) == [
               %{
                 feature: :secrets,
                 turns: :off,
                 with: [:factory, :workflow_model, :organisation_variables]
               }
             ]
    end

    test "a feature turned off stays off where another row turns on one that needs it" do
      current = [:observability, :security, :secrets]
      wanted = [:observability, :security, :factory]

      assert Saved.close(current, wanted) == [:observability, :security]

      assert Saved.preview(current, wanted) == [
               %{feature: :secrets, turns: :off, with: []},
               %{feature: :factory, turns: :on, with: []}
             ]
    end
  end

  describe "locks/0" do
    test "observability always; registry off without QORY_REGISTRY; factory with adapters set" do
      assert Saved.locks() == %{
               observability: {:on, :always},
               registry: {:off, :no_registry}
             }

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      Application.put_env(:apiary, :installed_adapters, ["tracker"])

      # What factory needs, directly or through another, is locked on with it.
      assert Saved.locks() == %{
               observability: {:on, :always},
               security: {:on, {:needed_by, :factory}},
               secrets: {:on, {:needed_by, :factory}},
               factory: {:on, :installed_adapters}
             }

      Application.put_env(:apiary, :installed_adapters, [])
      Application.put_env(:apiary, :installed_nodes, %{pool: "pool", gateway: nil, url: nil})
      assert Saved.locks().factory == {:on, :installed_adapters}
      assert Saved.locks().secrets == {:on, {:needed_by, :factory}}
    end
  end

  describe "the list in force" do
    test "with nothing saved, the defaults, without registry where QORY_REGISTRY is not set" do
      assert Saved.current() == %{features: defaults(), version: 0, source: :default}
      assert Saved.load() == defaults()

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      assert Saved.load() == Enum.filter(Features.all(), &(&1 in defaults() or &1 == :registry))
    end

    test "the saved list, through the locks" do
      store!(["security", "secrets", "factory", "registry"])

      # observability is locked on, so security and factory keep their need; registry is
      # locked off without QORY_REGISTRY.
      assert Saved.current() == %{
               features: [:observability, :security, :secrets, :factory],
               version: 1,
               source: :saved
             }

      # A feature whose needs are not all on is off.
      store!(["observability", "secrets", "factory"])
      assert Saved.load() == [:observability]

      # Adapters set in the environment turn factory on, with what it needs.
      store!(["observability"])
      Application.put_env(:apiary, :installed_adapters, ["tracker"])
      assert Saved.load() == [:observability, :security, :secrets, :factory]
    end

    test "a saved name this release does not have is skipped with one log line a node" do
      # A name no other test reads: the node keeps the names it logged.
      name = "teleport_#{System.unique_integer([:positive])}"
      store!(["observability", name, "security"])

      log =
        capture_log(fn ->
          assert Saved.load() == [:observability, :security]
          assert Saved.load() == [:observability, :security]
          assert Saved.refresh() == [:observability, :security]
        end)

      assert log =~
               "Features: skipped the saved feature #{name}, which this release does not have."

      assert length(String.split(log, "skipped the saved feature")) == 2
    end

    test "QORY_FEATURES wins, and each boot saves its list once" do
      store!(["observability"])
      Application.put_env(:apiary, :features_setting, "all-workflow_model")

      assert Saved.env?()
      assert Saved.boot() == defaults() -- [:workflow_model]
      assert Features.enabled() == defaults() -- [:workflow_model]
      assert row().features == Enum.map(defaults() -- [:workflow_model], &to_string/1)
      assert row().features_version == 2
      assert Saved.current().source == :env

      # The same list again changes nothing.
      Saved.boot()
      assert row().features_version == 2

      # Removed, the instance keeps the variable's list.
      Application.put_env(:apiary, :features_setting, " ")
      refute Saved.env?()
      assert Saved.refresh() == defaults() -- [:workflow_model]
      assert Saved.current().source == :saved
    end
  end

  describe "a feature the saved list has not seen" do
    test "a default feature takes its default: on, and on after a save", %{scope: scope} do
      # Saved by a release without path_rules, which this one turns on by default.
      store!(names(defaults() -- [:path_rules]), Features.all() -- [:path_rules])
      assert :path_rules in Saved.load()
      assert :path_rules in Saved.current().features

      # A save of another change keeps it on, and marks every feature seen.
      %{features: before, version: version} = Saved.current()

      assert {:ok, %{features: features}} =
               Saved.save(scope, before -- [:workflow_model], version)

      assert :path_rules in features
      assert Enum.sort(row().features_seen) == Enum.sort(names(Features.all()))
    end

    test "registry is not seen while QORY_REGISTRY is not set: setting it turns it on",
         %{scope: scope} do
      %{features: before, version: version} = Saved.current()
      assert {:ok, _current} = Saved.save(scope, before -- [:path_rules], version)
      refute "registry" in row().features_seen
      refute :registry in Saved.load()

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      assert :registry in Saved.load()
      refute :path_rules in Saved.load()
    end

    # The lock that turns registry off where QORY_REGISTRY is not set is the node's, so a
    # save made there leaves registry saved as the nodes with the variable saved it.
    test "a save on a node without QORY_REGISTRY keeps registry saved", %{scope: scope} do
      store!(names(defaults() ++ [:registry]))
      %{features: before, version: version} = Saved.current()
      refute :registry in before

      assert {:ok, _current} = Saved.save(scope, before -- [:path_rules], version)
      assert "registry" in row().features
      refute "path_rules" in row().features

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      assert :registry in Saved.load()
    end

    test "a save on a node without QORY_REGISTRY drops registry with a feature it needs",
         %{scope: scope} do
      store!(names(defaults() ++ [:registry]))
      %{features: before, version: version} = Saved.current()
      [need | _others] = Features.needs(:registry)

      assert {:ok, %{version: version}} =
               Saved.save(scope, Saved.close(before, before -- [need]), version)

      refute "registry" in row().features
      refute Atom.to_string(need) in row().features

      # Turning the need on again from this node leaves registry off.
      assert {:ok, _current} = Saved.save(scope, before, version)
      assert Atom.to_string(need) in row().features
      refute "registry" in row().features
    end

    test "an opt-in feature takes its default: off, and registry by QORY_REGISTRY" do
      [opt_in | _others] = Features.opt_in() -- [:registry]
      unseen = [opt_in, :registry]

      store!(names(defaults() -- [:path_rules]), Features.all() -- unseen)
      refute opt_in in Saved.load()
      refute :registry in Saved.load()
      refute :path_rules in Saved.load()

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      assert :registry in Saved.load()
      refute opt_in in Saved.load()
    end

    test "a feature that was seen and turned off stays off" do
      store!(names(defaults() -- [:path_rules]))
      refute :path_rules in Saved.load()
    end

    test "a save that changes no feature marks every feature seen, and keeps each one on",
         %{scope: scope} do
      # Saved by a release without path_rules, which this one turns on by default.
      store!(names(defaults() -- [:path_rules]), Features.all() -- [:path_rules])
      %{features: features, version: version} = Saved.current()
      assert :path_rules in features

      assert {:ok, %{features: ^features, version: ^version}} =
               Saved.save(scope, features, version)

      assert "path_rules" in row().features_seen
      assert "path_rules" in row().features
      assert :path_rules in Saved.load()
      assert length(entries()) == 0
    end

    test "a boot with QORY_FEATURES set marks every feature seen" do
      store!(["observability"], [:observability])
      Application.put_env(:apiary, :features_setting, "all-workflow_model")
      Saved.boot()

      # The edition's config features too: the variable's list has the ones the config
      # turns on (`c:Apiary.Edition.config_features/0`).
      assert Enum.sort(row().features_seen) == Enum.sort(names(Features.all() -- [:registry]))
    end
  end

  describe "save/3" do
    test "saves the list closed over the needs, with one entry, and writes the node's copy",
         %{scope: scope} do
      %{features: before, version: 0} = Saved.current()
      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, "instance_features")
      :ok = Cache.subscribe()

      assert {:ok, %{features: features, version: 1, source: :saved}} =
               Saved.save(scope, before -- [:secrets], 0)

      assert features == before -- [:secrets, :factory, :workflow_model, :organisation_variables]
      assert Features.enabled() == features
      assert row().features == Enum.map(features, &to_string/1)
      assert_receive {Cache, :changed}
      assert_receive {Cache, :written, ^features}

      assert [entry] = entries()
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      assert {entry.before, entry.after} ==
               {%{"features" => Enum.map(before, &to_string/1)},
                %{"features" => Enum.map(features, &to_string/1)}}

      # The names of the features are taken too; the same list again writes nothing.
      assert {:ok, %{features: ^features, version: 1}} =
               Saved.save(scope, Enum.map(features, &to_string/1), 1)

      assert length(entries()) == 1
    end

    test "refuses a save made from an older read", %{scope: scope} do
      assert {:ok, %{version: 1}} = Saved.save(scope, defaults() -- [:path_rules], 0)
      assert Saved.save(scope, defaults(), 0) == {:error, :stale}
      assert row().features_version == 1
      assert length(entries()) == 1
    end

    test "refuses a change to a locked feature", %{scope: scope} do
      assert Saved.save(scope, [], 0) == {:error, {:locked, :observability}}
      assert Saved.save(scope, Features.all(), 0) == {:error, {:locked, :registry}}

      Application.put_env(:apiary, :installed_adapters, ["tracker"])
      assert Saved.save(scope, defaults() -- [:factory], 0) == {:error, {:locked, :factory}}
      # What factory needs is locked with it.
      assert Saved.save(scope, defaults() -- [:secrets], 0) == {:error, {:locked, :secrets}}

      assert is_nil(row()) or is_nil(row().features)
      assert entries() == []
    end

    test "refuses any change while QORY_FEATURES is set", %{scope: scope} do
      Application.put_env(:apiary, :features_setting, "all")
      assert Saved.save(scope, defaults() -- [:path_rules], 0) == {:error, :env}
      assert entries() == []
    end

    test "saves nothing before the migration of its columns", %{scope: scope} do
      Repo.query!("ALTER TABLE instance_settings DROP COLUMN features_seen")

      assert Saved.save(scope, defaults() -- [:path_rules], 0) == {:error, :not_migrated}
      assert Saved.current().source == :default
      assert entries() == []
    end

    test "refuses a name that is no feature", %{scope: scope} do
      assert Saved.save(scope, ["observability", "teleport"], 0) == {:error, :unknown_feature}
    end

    test "is an instance admin's alone" do
      %{scope: owner} = sign_up_fixture()
      assert {:error, reason} = Saved.save(owner, [:observability], 0)
      assert reason in [:not_found, :forbidden]
      assert Saved.save(nil, [:observability], 0) == {:error, :not_found}
      assert entries() == []
    end
  end

  test "running_runs/0 counts the runs running in every workspace", %{scope: scope} do
    assert Saved.running_runs() == 0

    for state <- ["running", "running", "pending", "completed"] do
      Apiary.RunEventsFixtures.run_fixture(scope, %{state: state})
    end

    assert Saved.running_runs() == 2
  end

  describe "Apiary.Features.Cache, each node's copy" do
    test "reads the list when it starts, and again when another node saves" do
      store!(["observability", "security"])
      :ok = Cache.subscribe()

      start_supervised!(Cache)
      assert Features.enabled() == [:observability, :security]
      assert_receive {Cache, :written, [:observability, :security]}

      # Another node saves: its row and its broadcast reach this node's copy.
      store!(["observability", "security", "path_rules"])
      Cache.changed()

      assert_receive {Cache, :written, [:observability, :security, :path_rules]}
      assert Features.enabled() == [:observability, :security, :path_rules]
    end

    test "a node that missed the broadcast reads the list when a node joins" do
      store!(["observability", "security"])
      :ok = Cache.subscribe()
      start_supervised!(Cache)
      assert_receive {Cache, :written, [:observability, :security]}

      # Saved on another node, its broadcast not received here.
      store!(["observability", "security", "path_rules"])
      refute_receive {Cache, :written, _features}, 50

      send(Cache, {:nodeup, :"apiary@10.0.0.2"})
      assert_receive {Cache, :written, [:observability, :security, :path_rules]}
    end

    test "keeps the copy while the database is down, logs once, and reads it once it is back" do
      down = Apiary.Features.SavedTest.Down
      store!(["observability", "security"])
      Application.put_env(:apiary, :features, [:observability])
      :persistent_term.put({down, :down}, true)
      :persistent_term.put({down, :test}, self())

      on_exit(fn ->
        :persistent_term.erase({down, :down})
        :persistent_term.erase({down, :test})
      end)

      :ok = Cache.subscribe()

      # Started, or started again, while the database is down: the cache stays up through
      # several checks and a node joining, and the copy stays as it was.
      log =
        capture_log(fn ->
          pid = start_supervised!({Cache, interval: 20, saved: down})
          send(Cache, {:nodeup, :"apiary@10.0.0.2"})
          Process.sleep(150)
          assert Process.alive?(pid)
          assert Features.enabled() == [:observability]
        end)

      line =
        "Features: reading the saved features failed (connection error). This node keeps " <>
          "the features in force and reads them again in 0 seconds."

      assert length(String.split(log, line)) == 2
      refute log =~ "connection refused"

      # The first read that succeeds is the start's, which the failed start skipped.
      :persistent_term.put({down, :down}, false)
      assert_receive {^down, :booted}, 1_000
      assert_receive {Cache, :written, [:observability, :security]}, 1_000
      refute_receive {^down, :booted}, 100
    end

    test "a node that missed the broadcast reads the list once the version changed" do
      store!(["observability", "security"])
      :ok = Cache.subscribe()
      start_supervised!({Cache, interval: 20})
      assert_receive {Cache, :written, [:observability, :security]}

      # Saved on another node, its broadcast not received here.
      store!(["observability", "security", "path_rules"])
      assert_receive {Cache, :written, [:observability, :security, :path_rules]}, 1_000
      assert Features.enabled() == [:observability, :security, :path_rules]
    end
  end

  describe "the work at boot" do
    test "the registry's name is made where QORY_REGISTRY is set, whatever the features" do
      config = Application.get_env(:apiary, Apiary.Registry.InstanceName)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Registry.InstanceName, config) end)
      Application.put_env(:apiary, Apiary.Registry.InstanceName, enabled: true)
      Application.put_env(:apiary, :features, [:observability])

      assert Apiary.Registry.InstanceName.children() == []

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      assert Apiary.Registry.InstanceName.children() == [Apiary.Registry.InstanceName]
    end

    @tag :tmp_dir
    test "the registry's key is checked where QORY_REGISTRY is set, whatever the features",
         %{tmp_dir: dir} do
      config = Application.get_env(:apiary, Apiary.Registry)
      settings = Application.fetch_env(:apiary, Apiary.Registry.Settings)

      on_exit(fn ->
        Application.put_env(:apiary, Apiary.Registry, config)

        case settings do
          {:ok, kept} -> Application.put_env(:apiary, Apiary.Registry.Settings, kept)
          :error -> Application.delete_env(:apiary, Apiary.Registry.Settings)
        end
      end)

      Application.put_env(:apiary, :features, [:observability])
      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      Application.put_env(:apiary, Apiary.Registry, key_file: Path.join(dir, "missing.key"))
      Application.delete_env(:apiary, Apiary.Registry.Settings)

      assert_raise ArgumentError, ~r/^Run bin\/keys with QORY_REGISTRY set/, fn ->
        Apiary.Registry.boot!()
      end
    end
  end
end

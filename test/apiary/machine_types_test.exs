defmodule Apiary.MachineTypesTest do
  @moduledoc """
  The instance's machine types (`Apiary.MachineTypes`): the seeded default, the type a run
  is queued on, the fit of a pool's offers, what uses a type, the change of a type by an
  instance admin after a recent sign-in, with its entry in the instance's trail, and the
  refusals: a reserved or invalid name, a name twice, a spec out of bounds or that no pool
  fits, and the deletion of the default or of a type a workflow uses.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and a
  # change of a type locks the table of types.
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, walks_resolved!: 0]
  import Apiary.MachineTypesFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, MachineTypes, Processes}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.MachineTypes.MachineType
  alias Apiary.Processes.{TypeTemplate, TypeTemplates}
  alias Apiary.WorkItems.WorkItem

  @standard %{
    "vcpus" => 2,
    "memory_mib" => 4096,
    "disk_gib" => 30,
    "arch" => "amd64",
    "virtualization" => false
  }

  @large %{
    key: "large",
    name: "Large",
    vcpus: 4,
    memory_mib: 16_384,
    disk_gib: 60,
    arch: "amd64"
  }

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    %{scope: signed_in(scope)}
  end

  # `scope` as a sign-in `minutes` ago leaves it (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in(scope, minutes \\ 0),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), -minutes, :minute))

  defp entries do
    Repo.all(
      from e in Entry,
        where: e.action == "instance.configure",
        where: e.organisation_id == ^Apiary.Edition.instance_organisation_id(),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp names, do: Enum.map(MachineTypes.list(), &{&1.key, &1.is_default})

  describe "the seeded default" do
    test "is standard: 2 vCPUs, 4 GiB, 30 GiB of disk, amd64, no virtualization" do
      assert [
               %MachineType{key: "standard", name: "Standard", is_default: true} = standard,
               %MachineType{key: "browser", name: "Browser tests", is_default: false} = browser
             ] = MachineTypes.list()

      assert MachineTypes.spec(standard) == @standard
      assert MachineTypes.spec(browser) == @standard
      assert MachineTypes.default_type().id == standard.id
    end

    test "the database keeps one default, and no type named default" do
      # Each in a savepoint, so the test's transaction goes on after the refusal.
      assert_raise Ecto.ConstraintError, ~r/machine_types_one_default_index/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%MachineType{
            key: "second",
            name: "Second",
            vcpus: 1,
            memory_mib: 512,
            disk_gib: 1,
            arch: "amd64",
            is_default: true
          })
        end)
      end

      assert_raise Postgrex.Error, ~r/machine_types_key_check/, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "INSERT INTO machine_types (id, key, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), 'default', 'Default', 1, 512, 1, 'amd64', false, false, now(), now())"
          )
        end)
      end

      for name <- [
            "Two\nlines",
            "Tab\there",
            "Line\u2028separator",
            String.duplicate("a", 101),
            String.duplicate("é", 101)
          ] do
        assert_raise Postgrex.Error, ~r/machine_types_name_check/, fn ->
          Repo.transaction(fn ->
            Repo.query!(
              "INSERT INTO machine_types (id, key, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), 'other', $1, 1, 512, 1, 'amd64', false, false, now(), now())",
              [name]
            )
          end)
        end
      end

      assert names() == [{"standard", true}, {"browser", false}]
    end
  end

  describe "resolve/1" do
    test "is the type by its key, else the default type" do
      machine_type_fixture(@large)

      assert MachineTypes.resolve("large") == {"large", spec()}

      for name <- [nil, "default", "gone"],
          do: assert(MachineTypes.resolve(name) == {"standard", @standard}, inspect(name))
    end

    test "is default with no spec on an instance with no default type" do
      Repo.delete_all(MachineType)
      assert MachineTypes.resolve("large") == {"default", nil}
    end
  end

  describe "the fit of a pool's offers" do
    test "fits?/2: each number at least the spec's, the same arch, virtualization if needed" do
      assert MachineTypes.fits?(spec(), spec())
      assert MachineTypes.fits?(spec(%{vcpus: 8, disk_gib: 100}), spec())
      assert MachineTypes.fits?(spec(%{virtualization: true}), spec())

      for offer <- [
            spec(%{vcpus: 3}),
            spec(%{memory_mib: 16_383}),
            spec(%{disk_gib: 59}),
            spec(%{arch: "arm64"})
          ],
          do: refute(MachineTypes.fits?(offer, spec()), inspect(offer))

      refute MachineTypes.fits?(spec(), spec(%{virtualization: true}))
    end

    test "fitted?/2 refuses a spec no offer fits only while a pool has offers", %{scope: scope} do
      assert MachineTypes.fitted?(spec(%{vcpus: 64}), [])

      pool = pool_fixture(scope)
      assert MachineTypes.fitted?(spec(%{vcpus: 64}), MachineTypes.pools())

      with_offers(pool, [spec(%{vcpus: 8})])
      assert MachineTypes.fitted?(spec(), MachineTypes.pools())
      refute MachineTypes.fitted?(spec(%{vcpus: 64}), MachineTypes.pools())
    end

    test "serves?/2: a pool with offers serves the types they fit; one without, the default",
         %{scope: scope} do
      large = machine_type_fixture(@large)
      standard = standard_type()
      pool = pool_fixture(scope)

      assert MachineTypes.serves?(pool, standard)
      refute MachineTypes.serves?(pool, large)

      pool = with_offers(pool, [spec(%{vcpus: 8, memory_mib: 32_768, disk_gib: 100})])
      assert MachineTypes.serves?(pool, large)
      assert MachineTypes.serves?(pool, standard)

      pool = with_offers(pool, [spec(%{arch: "arm64"})])
      refute MachineTypes.serves?(pool, standard)
    end
  end

  describe "unserved/2" do
    test "is the type of the newest waiting run when no pool that serves the workspace takes it",
         %{scope: scope} do
      machine_type_fixture(@large)
      work_item = work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      # No pool serves the workspace: unserved/2 is nil.
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil

      pool = pool_fixture(scope)
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [machine_type: "large", machine_spec: spec(), machine_type_was_default: false]
      )

      assert MachineTypes.unserved(scope.workspace, work_item.id) == "large"

      with_offers(pool, [spec(%{vcpus: 8})])
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil

      with_offers(pool, [spec(%{arch: "arm64"})])
      assert MachineTypes.unserved(scope.workspace, work_item.id) == "large"

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [state: :claimed])
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil
    end

    test "a run queued on the default is served by a pool without offers after another type becomes the default",
         %{scope: scope} do
      work_item = work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      assert {run.machine_type, run.machine_type_was_default} == {"standard", true}
      pool_fixture(scope)

      make_default!(machine_type_fixture(@large))
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [machine_type_was_default: false]
      )

      assert MachineTypes.unserved(scope.workspace, work_item.id) == "standard"

      # A run of the default type is served, whatever its type was when it was queued.
      make_default!(standard_type())
      assert MachineTypes.unserved(scope.workspace, work_item.id) == nil
    end
  end

  describe "what uses a type" do
    @tag needs: :workflow_model
    test "the entries that pick it, and a document whose default it is, by place and workflow",
         %{scope: scope} do
      machine_type_fixture(@large)

      document =
        Processes.default_document("software")
        |> Map.put("machine", "large")
        |> update_in(["stages", Access.at(1), "sequence"], fn _ ->
          [%{"workflow" => "write-specs", "machine" => "standard"}, %{"workflow" => "review"}]
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      place = %{place: scope.workspace.name, organisation_id: scope.organisation.id}

      uses = MachineTypes.uses("large")
      assert Map.put(place, :workflow, "review") in uses
      refute Map.put(place, :workflow, "write-specs") in uses
      assert Map.put(place, :workflow, "write-specs") in MachineTypes.uses("standard")

      counts = MachineTypes.used_by()
      assert counts["large"] >= 1
      assert counts["standard"] >= 1
    end

    @tag needs: :workflow_model
    test "an entry or a document whose type is default runs on the instance's default type",
         %{scope: scope} do
      machine_type_fixture(@large)

      document =
        Processes.default_document("software")
        |> Map.put("machine", "large")
        |> update_in(["stages", Access.at(1), "sequence"], fn _ ->
          [%{"workflow" => "write-specs", "machine" => "default"}, %{"workflow" => "review"}]
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      place = %{place: scope.workspace.name, organisation_id: scope.organisation.id}

      assert Map.put(place, :workflow, "write-specs") in MachineTypes.uses("standard")
      refute Map.put(place, :workflow, "write-specs") in MachineTypes.uses("large")
      assert Map.put(place, :workflow, "review") in MachineTypes.uses("large")

      counts = MachineTypes.used_by()

      for type <- ~w(standard large),
          do: assert(counts[type] == length(MachineTypes.uses(type)), type)
    end

    @tag needs: :workflow_model
    test "used_by/0 counts the documents uses/1 reads: trial versions and workspace types",
         %{scope: scope} do
      machine_type_fixture(@large)
      place = %{place: scope.workspace.name, organisation_id: scope.organisation.id}

      document =
        update_in(
          Processes.default_document("software"),
          ["stages", Access.at(1), "sequence"],
          fn _ -> [%{"workflow" => "write-specs", "machine" => "large"}] end
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document, trial: true)
      assert MachineTypes.uses("large") == [Map.put(place, :workflow, "write-specs")]
      assert MachineTypes.used_by()["large"] == 1

      newest = TypeTemplates.newest("qory.software")

      typed =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "large"
        )

      {:ok, _version} = TypeTemplates.save(scope, "qory.software", typed)
      assert length(MachineTypes.uses("large")) == 2

      # A workspace type's use has no organisation.
      assert [%{organisation_id: nil}] =
               Enum.reject(
                 MachineTypes.uses("large"),
                 &(&1 == Map.put(place, :workflow, "write-specs"))
               )

      assert MachineTypes.used_by()["large"] == 2
    end

    test "a document whose every entry picks a type uses its default as the document alone" do
      document = %{
        "machine" => "large",
        "stages" => [%{"sequence" => [%{"workflow" => "a", "machine" => "standard"}]}]
      }

      assert MachineTypes.entries(document) == [%{"workflow" => "a", "machine" => "standard"}]
    end
  end

  describe "hold/0" do
    defp share_locked? do
      Repo.query!("""
      SELECT count(*) FROM pg_locks
      WHERE locktype = 'relation' AND relation = 'machine_types'::regclass
        AND mode = 'ShareLock' AND pid = pg_backend_pid()
      """).rows == [[1]]
    end

    @tag needs: :workflow_model
    test "a save of a workspace's process holds the table of types until it commits",
         %{scope: scope} do
      refute share_locked?()
      current = Processes.current(scope.workspace).document
      changed = put_in(current, ["stages", Access.at(0), "description"], "Changed.")
      {:ok, _version} = Processes.save(scope, scope.workspace, changed)
      assert share_locked?()
    end

    @tag needs: :workflow_model
    test "a save of a workspace type's process holds the table of types until it commits",
         %{scope: scope} do
      refute share_locked?()
      newest = TypeTemplates.newest("qory.software")
      changed = put_in(newest.document, ["stages", Access.at(0), "description"], "Changed.")
      {:ok, _version} = TypeTemplates.save(scope, "qory.software", changed)
      assert share_locked?()
    end
  end

  describe "create/2" do
    test "adds a type, with an instance.configure entry of the type after", %{scope: scope} do
      assert {:ok, %MachineType{key: "large", is_default: false}} =
               MachineTypes.create(scope, @large)

      assert names() == [{"standard", true}, {"browser", false}, {"large", false}]

      assert [%Entry{before: before, after: after_}] = entries()
      assert before == %{"machine_type" => nil}

      assert after_ == %{
               "machine_type" =>
                 Map.merge(spec(), %{
                   "key" => "large",
                   "name" => "Large",
                   "default" => false
                 })
             }
    end

    test "made the default, makes the default before it no longer the default",
         %{scope: scope} do
      assert {:ok, %MachineType{is_default: true}} =
               MachineTypes.create(scope, Map.put(@large, :is_default, true))

      assert {:ok, %MachineType{is_default: true}} =
               MachineTypes.create(
                 scope,
                 Map.merge(@large, %{key: "larger", name: "Larger", is_default: true})
               )

      assert names() == [
               {"standard", false},
               {"browser", false},
               {"large", false},
               {"larger", true}
             ]
    end

    test "a reserved, invalid or taken key, a bad name, or a number out of bounds is an error",
         %{scope: scope} do
      for {key, validation} <- [
            {"default", :reserved},
            {"Large", :format},
            {"1large", :format},
            {"large_x", :format},
            {String.duplicate("a", 65), :format}
          ] do
        assert {:error, changeset} = MachineTypes.create(scope, %{@large | key: key})
        assert {_, opts} = changeset.errors[:key], key
        assert opts[:validation] == validation, key
      end

      assert {:error, changeset} = MachineTypes.create(scope, %{@large | key: "standard"})
      assert {_, [constraint: :unique, constraint_name: _]} = changeset.errors[:key]

      # A name another type has, ignoring case.
      assert {:error, changeset} = MachineTypes.create(scope, %{@large | name: "STANDARD"})
      assert {_, [constraint: :unique, constraint_name: _]} = changeset.errors[:name]

      for name <- [
            "",
            "Two\nlines",
            "Tab\there",
            "Line\u2028separator",
            String.duplicate("a", 101),
            String.duplicate("é", 101)
          ] do
        assert {:error, changeset} = MachineTypes.create(scope, %{@large | name: name})
        assert Keyword.has_key?(changeset.errors, :name), inspect(name)
      end

      # 100 code points of two bytes each are a name, as the diagnostics contract counts.
      assert MachineType.changeset(%MachineType{}, %{@large | name: String.duplicate("é", 100)}).valid?

      for {field, value} <- [
            vcpus: 0,
            vcpus: 1025,
            memory_mib: 511,
            memory_mib: 8_388_609,
            disk_gib: 0,
            disk_gib: 65_537,
            arch: "riscv64"
          ] do
        assert {:error, changeset} = MachineTypes.create(scope, Map.put(@large, field, value))
        assert Keyword.has_key?(changeset.errors, field), "#{field} #{value}"
      end

      assert [] = entries()

      assert {:ok, _} =
               MachineTypes.create(scope, %{
                 @large
                 | key: String.duplicate("a", 64),
                   name: String.duplicate("A", 100)
               })
    end

    test "refuses a type no pool fits while a pool has offers", %{scope: scope} do
      pool = pool_fixture(scope)
      with_offers(pool, [spec(%{vcpus: 2})])

      assert {:error, changeset} = MachineTypes.create(scope, @large)
      assert {_, opts} = changeset.errors[:vcpus]
      assert opts[:validation] == :no_pool

      with_offers(pool, [spec(%{vcpus: 8})])
      assert {:ok, _} = MachineTypes.create(scope, @large)
    end

    test "is for an instance admin after a recent sign-in", %{scope: scope} do
      assert MachineTypes.create(signed_in(scope, 21), @large) == {:error, :sudo}

      %{scope: member} = member_fixture(scope, :member)
      assert MachineTypes.create(member, @large) == {:error, :forbidden}
      assert MachineTypes.create(nil, @large) == {:error, :not_found}

      assert names() == [{"standard", true}, {"browser", false}]
    end
  end

  describe "update/3 and make_default/2" do
    test "change the key, the name and the spec, each with an entry", %{
      scope: scope
    } do
      large = machine_type_fixture(@large)

      assert {:ok, updated} =
               MachineTypes.update(scope, large, %{
                 "vcpus" => 8,
                 "name" => "Large builds",
                 "key" => "large-builds"
               })

      assert {updated.key, updated.name, updated.vcpus} == {"large-builds", "Large builds", 8}
      assert MachineTypes.get("large") == nil

      {:ok, updated} = MachineTypes.update(scope, updated, %{"key" => "large"})

      {:ok, updated} = MachineTypes.update(scope, updated, %{"disk_gib" => 80})
      assert {:ok, %MachineType{is_default: true}} = MachineTypes.make_default(scope, updated)
      assert names() == [{"standard", false}, {"browser", false}, {"large", true}]

      assert [first, second, third, fourth] = entries()
      assert first.before["machine_type"]["vcpus"] == 4
      assert first.after["machine_type"]["vcpus"] == 8
      assert first.after["machine_type"]["name"] == "Large builds"
      assert first.after["machine_type"]["key"] == "large-builds"
      assert second.after["machine_type"]["key"] == "large"
      assert third.after["machine_type"]["disk_gib"] == 80
      assert fourth.after["machine_type"]["default"] == true
    end

    test "a type deleted since is not found", %{scope: scope} do
      large = machine_type_fixture(@large)
      Repo.delete!(large)
      assert MachineTypes.update(scope, large, %{"vcpus" => 8}) == {:error, :not_found}
      assert MachineTypes.make_default(scope, large) == {:error, :not_found}
    end
  end

  describe "run_key/2" do
    test "is the entry's key where a type has it, else the workspace's default, else default" do
      # The type browser is seeded.
      machine_type_fixture(key: "large")

      assert MachineTypes.run_key("browser", "large") == "browser"
      assert MachineTypes.run_key("gone", "large") == "large"
      assert MachineTypes.run_key("gone", "also-gone") == "default"
      assert MachineTypes.run_key("gone", nil) == "default"
      assert MachineTypes.run_key(nil, nil) == "default"
      assert MachineTypes.run_key("default", "large") == "default"
    end
  end

  describe "a key change" do
    # The workspace's version 1 as a copy of a harness's `process.yaml` that uses `key`.
    defp made_from_harness(workspace, key) do
      %Processes.Version{number: 1} = version = Processes.current(workspace)

      document =
        put_in(
          version.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          key
        )

      {1, _rows} =
        Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [
            document: document,
            template: %{
              "source" => "repository",
              "git" => "https://git.example.com/acme/factory-harness.git",
              "commit" => "3c9e1a7" <> String.duplicate("0", 33),
              "module" => "web"
            }
          ]
        )

      document
    end

    test "key_change/1 counts the processes, the waiting runs and each organisation's files",
         %{scope: scope} do
      browser = browser_type()

      assert MachineTypes.key_change(browser) == %{
               workspaces: 0,
               templates: 0,
               waiting: 0,
               files: [],
               organisations: []
             }

      made_from_harness(scope.workspace, "browser")
      %{scope: other} = sign_up_fixture()
      made_from_harness(other.workspace, "browser")

      work_item = work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [machine_type: "browser", machine_spec: spec(), machine_type_was_default: false]
      )

      # The file of a harness repository counts once for each organisation whose
      # workspaces' processes come from it, with no address, workspace or workflow.
      assert %{workspaces: 2, templates: 0, waiting: 1, files: [], organisations: organisations} =
               MachineTypes.key_change(browser)

      assert organisations ==
               Enum.sort_by(
                 [
                   %{name: scope.organisation.name, files: 1},
                   %{name: other.organisation.name, files: 1}
                 ],
                 &{&1.name, &1.files}
               )
    end

    test "lists a file saved from the Qory harness at an address the instance had before", %{
      scope: scope
    } do
      %Processes.Version{number: 1} = version = Processes.current(scope.workspace)

      {1, _rows} =
        Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [
            document:
              put_in(
                version.document,
                ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
                "browser"
              ),
            template: %{
              "source" => "qory",
              "git" => "https://git.example.com/mirror/harness.git",
              "commit" => "5b2f8d4" <> String.duplicate("0", 33),
              "module" => "software-factory"
            }
          ]
        )

      # The Qory harness's file is the instance admin's, not the organisation's.
      assert %{
               files: [
                 %{
                   repository: "git.example.com/mirror/harness",
                   module: "software-factory",
                   commit: "5b2f8d4" <> _zeros
                 }
               ],
               organisations: []
             } = MachineTypes.key_change(browser_type())
    end

    @tag needs: :workflow_model
    test "lists no file for a key that a person's edit added after the harness's commit", %{
      scope: scope
    } do
      %Processes.Version{number: 1} = version = Processes.current(scope.workspace)
      refute MachineTypes.uses_key?(version.document, "browser")

      {1, _rows} =
        Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [
            template: %{
              "source" => "repository",
              "git" => "https://git.example.com/acme/factory-harness.git",
              "commit" => "3c9e1a7" <> String.duplicate("0", 33),
              "module" => "web"
            }
          ]
        )

      edited =
        put_in(
          version.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {:ok, %Processes.Version{number: 2}} = Processes.save(scope, scope.workspace, edited)

      assert %{workspaces: 1, files: [], organisations: []} =
               MachineTypes.key_change(browser_type())
    end

    test "keeps a workspace type's copy of the Qory harness, and lists the harness's file", %{
      scope: scope
    } do
      browser = browser_type()
      copy = TypeTemplates.newest("qory.software")
      assert copy.release != nil

      document =
        put_in(
          copy.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {1, _rows} =
        Repo.update_all(from(t in TypeTemplate, where: t.id == ^copy.id),
          set: [document: document]
        )

      git = Apiary.Harnesses.Qory.git()

      assert MachineTypes.key_change(browser) == %{
               workspaces: 0,
               templates: 0,
               waiting: 0,
               files: [
                 %{
                   repository:
                     git
                     |> String.replace(~r{\A[a-z][a-z0-9+.-]*://}, "")
                     |> String.replace_suffix(".git", ""),
                   module: "software-factory",
                   path: "modules/software-factory/process.yaml",
                   commit: Apiary.Harnesses.Qory.current()
                 }
               ],
               organisations: []
             }

      assert {:ok, %MachineType{key: "ui-tests"}} =
               MachineTypes.update(scope, browser, %{"key" => "ui-tests"})

      # The copy is the newest version still, with the key of before: its runs start on
      # the default type until the harness changes the key.
      newest =
        Repo.one(
          from t in TypeTemplate,
            where: t.type == "qory.software",
            order_by: [desc: t.number],
            limit: 1
        )

      assert newest.id == copy.id
      assert newest.document == document

      refute Repo.exists?(from e in Entry, where: e.action == "workspace_type.edit")
    end

    @tag needs: :workflow_model
    test "saves a version of each current and trial process and workspace type that uses it",
         %{scope: scope} do
      browser = browser_type()
      v1 = made_from_harness(scope.workspace, "browser")
      work_item = work_item_fixture(scope)
      current = Processes.current(scope.workspace)

      {1, _rows} =
        Repo.update_all(
          from(w in WorkItem, where: w.id == ^work_item.id),
          set: [process_version_id: current.id]
        )

      trial_document = Map.put(v1, "machine", "browser")
      {:ok, trial} = Processes.save(scope, scope.workspace, trial_document, trial: true)

      newest = TypeTemplates.newest("qory.software")

      typed =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {:ok, typed} = TypeTemplates.save(scope, "qory.software", typed)

      assert %{workspaces: 1, templates: 1} = MachineTypes.key_change(browser)

      assert {:ok, %MachineType{key: "ui-tests"}} =
               MachineTypes.update(scope, browser, %{"key" => "ui-tests"})

      versions =
        Repo.all(
          from v in Processes.Version,
            where: v.workspace_id == ^scope.workspace.id,
            order_by: v.number
        )

      assert [
               {1, :past, ^v1, nil},
               {2, :dropped, _trial, _author},
               {3, :current, new_current, author},
               {4, :trial, new_trial, author}
             ] = Enum.map(versions, &{&1.number, &1.status, &1.document, &1.author_id})

      assert author == scope.user.id
      assert new_current == MachineTypes.rekey(v1, "browser", "ui-tests")
      assert new_trial == MachineTypes.rekey(trial_document, "browser", "ui-tests")
      assert new_trial["machine"] == "ui-tests"
      refute MachineTypes.uses_key?(new_current, "browser")
      assert Enum.at(versions, 1).id == trial.id

      # The work item moves to the version that replaced its version.
      assert Repo.get!(WorkItem, work_item.id).process_version_id ==
               Enum.at(versions, 2).id

      newest = TypeTemplates.newest("qory.software")
      assert newest.number == typed.number + 1
      assert newest.author_id == scope.user.id
      assert newest.document == MachineTypes.rekey(typed.document, "browser", "ui-tests")

      assert %Entry{details: %{"machine_key" => %{"from" => "browser", "to" => "ui-tests"}}} =
               Repo.one(
                 from e in Entry,
                   where: e.action == "workspace_type.edit",
                   order_by: [desc: e.inserted_at, desc: e.id],
                   limit: 1
               )

      assert MachineTypes.key_change(MachineTypes.get("ui-tests"))
             |> Map.take([:workspaces, :templates]) ==
               %{workspaces: 1, templates: 1}

      assert MachineTypes.key_change(%{browser | key: "browser"}).workspaces == 0

      saves =
        Repo.all(
          from e in Entry,
            where: e.action == "process.edit" and e.workspace_id == ^scope.workspace.id,
            order_by: [asc: e.inserted_at, asc: e.id]
        )

      assert [
               %{"change" => "save_trial"},
               %{"change" => "save", "machine_key" => %{"from" => "browser", "to" => "ui-tests"}},
               %{
                 "change" => "save_trial",
                 "machine_key" => %{"from" => "browser", "to" => "ui-tests"}
               }
             ] = Enum.map(saves, & &1.details)
    end

    @tag needs: :workflow_model
    test "updates the workspaces of every organisation, and moves the work items of a trial",
         %{scope: scope} do
      browser = browser_type()
      %{scope: other} = sign_up_fixture()
      v1 = made_from_harness(other.workspace, "browser")

      {:ok, trial} =
        Processes.save(other, other.workspace, Map.put(v1, "machine", "browser"), trial: true)

      assert trial.status == :trial
      work_item = work_item_fixture(other)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [process_version_id: trial.id]
        )

      assert {:ok, _type} = MachineTypes.update(scope, browser, %{"key" => "ui-tests"})

      assert [{1, :past}, {2, :dropped}, {3, :current}, {4, :trial}] =
               Repo.all(
                 from v in Processes.Version,
                   where: v.workspace_id == ^other.workspace.id,
                   order_by: v.number,
                   select: {v.number, v.status}
               )

      new_trial = Repo.get_by!(Processes.Version, workspace_id: other.workspace.id, number: 4)
      assert new_trial.document["machine"] == "ui-tests"
      refute MachineTypes.uses_key?(new_trial.document, "browser")
      assert new_trial.author_id == scope.user.id
      assert Repo.get!(WorkItem, work_item.id).process_version_id == new_trial.id

      # The entries are in the trail of the workspace's organisation, by the instance admin.
      assert [%{"change" => "save"}, %{"change" => "save_trial"}] =
               Repo.all(
                 from e in Entry,
                   where: e.action == "process.edit" and e.workspace_id == ^other.workspace.id,
                   where: e.organisation_id == ^other.organisation.id,
                   where: e.actor_id == ^scope.user.id,
                   order_by: [asc: e.inserted_at, asc: e.id],
                   select: e.details
               )
    end

    @tag needs: :factory
    test "moves a run that waits on the key to the key and version of after, which a pool claims, every other waiting run of the version to that version, and leaves a started run",
         %{scope: scope} do
      browser = browser_type()
      made_from_harness(scope.workspace, "browser")
      %Processes.Version{number: 1} = version = Processes.current(scope.workspace)
      place = handover_place_fixture(scope)

      [waiting, started] =
        for _run <- 1..2 do
          {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)

          {1, _rows} =
            Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
              set: [
                machine_type: "browser",
                machine_spec: MachineTypes.spec(browser),
                machine_type_was_default: false,
                process_version_id: version.id
              ]
            )

          run.id
        end

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^started), set: [state: :claimed])

      # A run that waits on another type, on the same version.
      {:ok, other} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^other.id),
          set: [process_version_id: version.id, machine_type: "standard"]
        )

      assert %{waiting: 1} = MachineTypes.key_change(browser)
      assert {:ok, _type} = MachineTypes.update(scope, browser, %{"key" => "ui-tests"})

      %Processes.Version{number: 2, id: rekeyed} = Processes.current(scope.workspace)

      assert %DispatchRun{state: :waiting, machine_type: "ui-tests", process_version_id: ^rekeyed} =
               Repo.get!(DispatchRun, waiting)

      assert %DispatchRun{state: :claimed, machine_type: "browser"} =
               started_run = Repo.get!(DispatchRun, started)

      assert started_run.process_version_id == version.id

      assert %DispatchRun{state: :waiting, machine_type: "standard", process_version_id: ^rekeyed} =
               Repo.get!(DispatchRun, other.id)

      :ok = walks_resolved!()

      assert {:ok, %{run: %{id: ^waiting}, dispatch: %{machine_type: "ui-tests"}}} =
               Dispatches.claim(place.key, Dispatches.now(), "", [
                 MachineTypes.spec(MachineTypes.get("ui-tests"))
               ])
    end

    @tag needs: :workflow_model
    test "a key change whose step fails saves nothing", %{scope: scope} do
      browser = browser_type()
      made_from_harness(scope.workspace, "browser")
      newest = TypeTemplates.newest("qory.software")

      typed =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {:ok, typed} = TypeTemplates.save(scope, "qory.software", typed)
      versions = Repo.all(from v in Processes.Version, order_by: v.id)

      # The save of the workspace type's version fails, after the workspace's version is
      # saved. The trigger is created in the test's transaction and rolled back with it.
      Repo.query!("""
      CREATE FUNCTION refuse_type_template_for_test() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'refused'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_type_template BEFORE INSERT ON type_template_versions
      FOR EACH ROW EXECUTE FUNCTION refuse_type_template_for_test()
      """)

      assert_raise Postgrex.Error, ~r/refused/, fn ->
        MachineTypes.update(scope, browser, %{"key" => "ui-tests"})
      end

      assert MachineTypes.get("browser")
      refute MachineTypes.get("ui-tests")
      assert Repo.all(from v in Processes.Version, order_by: v.id) == versions
      assert TypeTemplates.newest("qory.software").id == typed.id
      refute Repo.exists?(from e in Entry, where: not is_nil(e.details["machine_key"]))
    end

    test "rekey/3 changes the key in the document's machine and every entry's" do
      document = %{
        "machine" => "browser",
        "stages" => [
          %{
            "sequence" => [
              %{"workflow" => "a", "machine" => "browser"},
              %{
                "loop" => %{
                  "body" => [%{"workflow" => "b", "machine" => "browser"}, %{"workflow" => "c"}]
                }
              },
              %{"workflow" => "d", "machine" => "standard"}
            ]
          }
        ]
      }

      assert MachineTypes.uses_key?(document, "browser")

      assert MachineTypes.rekey(document, "browser", "ui-tests") == %{
               "machine" => "ui-tests",
               "stages" => [
                 %{
                   "sequence" => [
                     %{"workflow" => "a", "machine" => "ui-tests"},
                     %{
                       "loop" => %{
                         "body" => [
                           %{"workflow" => "b", "machine" => "ui-tests"},
                           %{"workflow" => "c"}
                         ]
                       }
                     },
                     %{"workflow" => "d", "machine" => "standard"}
                   ]
                 }
               ]
             }

      refute MachineTypes.uses_key?(%{"stages" => []}, "browser")
    end
  end

  describe "delete/2" do
    test "deletes a type no workflow uses, with an entry", %{scope: scope} do
      large = machine_type_fixture(@large)
      assert {:ok, _} = MachineTypes.delete(scope, large)
      assert names() == [{"standard", true}, {"browser", false}]
      assert [%Entry{before: %{"machine_type" => %{"key" => "large"}}} = entry] = entries()
      assert entry.after == %{"machine_type" => nil}
    end

    test "keeps the default", %{scope: scope} do
      assert MachineTypes.delete(scope, standard_type()) == {:error, :default}
      assert entries() == []
    end

    @tag needs: :workflow_model
    test "keeps a type a workflow uses, with the workflows", %{scope: scope} do
      large = machine_type_fixture(@large)

      document =
        update_in(
          Processes.default_document("software"),
          ["stages", Access.at(1), "sequence"],
          fn _ -> [%{"workflow" => "write-specs", "machine" => "large"}] end
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      assert MachineTypes.delete(scope, large) ==
               {:error,
                {:in_use,
                 [
                   %{
                     place: scope.workspace.name,
                     organisation_id: scope.organisation.id,
                     workflow: "write-specs"
                   }
                 ]}}

      assert MachineTypes.get("large")
    end
  end
end

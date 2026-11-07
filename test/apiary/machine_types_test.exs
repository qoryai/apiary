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

  import Apiary.MachineTypesFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, MachineTypes, Processes}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.MachineTypes.MachineType

  @standard %{
    "vcpus" => 2,
    "memory_mib" => 4096,
    "disk_gib" => 30,
    "arch" => "amd64",
    "virtualization" => false
  }

  @large %{name: "large", vcpus: 4, memory_mib: 16_384, disk_gib: 60, arch: "amd64"}

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

  defp names, do: Enum.map(MachineTypes.list(), &{&1.name, &1.is_default})

  describe "the seeded default" do
    test "is standard: 2 vCPUs, 4 GiB, 30 GiB of disk, amd64, no virtualization" do
      assert [%MachineType{name: "standard", is_default: true} = standard] = MachineTypes.list()
      assert MachineTypes.spec(standard) == @standard
      assert MachineTypes.default_type().id == standard.id
    end

    test "the database keeps one default, and no type named default" do
      # Each in a savepoint, so the test's transaction goes on after the refusal.
      assert_raise Ecto.ConstraintError, ~r/machine_types_one_default_index/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%MachineType{
            name: "second",
            vcpus: 1,
            memory_mib: 512,
            disk_gib: 1,
            arch: "amd64",
            is_default: true
          })
        end)
      end

      assert_raise Postgrex.Error, ~r/machine_types_name_check/, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "INSERT INTO machine_types (id, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), 'default', 1, 512, 1, 'amd64', false, false, now(), now())"
          )
        end)
      end

      assert names() == [{"standard", true}]
    end
  end

  describe "resolve/1" do
    test "is the type by its name, else the default type" do
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
      name = scope.workspace.name

      uses = MachineTypes.uses("large")
      assert %{place: name, workflow: "review"} in uses
      refute %{place: name, workflow: "write-specs"} in uses
      assert %{place: name, workflow: "write-specs"} in MachineTypes.uses("standard")

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
      name = scope.workspace.name

      assert %{place: name, workflow: "write-specs"} in MachineTypes.uses("standard")
      refute %{place: name, workflow: "write-specs"} in MachineTypes.uses("large")
      assert %{place: name, workflow: "review"} in MachineTypes.uses("large")

      counts = MachineTypes.used_by()

      for type <- ~w(standard large),
          do: assert(counts[type] == length(MachineTypes.uses(type)), type)
    end

    @tag needs: :workflow_model
    test "used_by/0 counts the documents uses/1 reads: trial versions and workspace types",
         %{scope: scope} do
      machine_type_fixture(@large)
      name = scope.workspace.name

      document =
        update_in(
          Processes.default_document("software"),
          ["stages", Access.at(1), "sequence"],
          fn _ -> [%{"workflow" => "write-specs", "machine" => "large"}] end
        )

      {:ok, _version} = Processes.save(scope, scope.workspace, document, trial: true)
      assert MachineTypes.uses("large") == [%{place: name, workflow: "write-specs"}]
      assert MachineTypes.used_by()["large"] == 1

      newest = Apiary.Processes.TypeTemplates.newest("qory.software")

      typed =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "large"
        )

      {:ok, _version} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)
      assert length(MachineTypes.uses("large")) == 2
      assert MachineTypes.used_by()["large"] == 2
    end

    test "a document whose every entry picks a type uses its default as the document alone" do
      document = %{
        "machine" => "large",
        "stages" => [%{"sequence" => [%{"workflow" => "a", "machine" => "standard"}]}]
      }

      assert MachineTypes.entries(document) == [%{"workflow" => "a", "machine" => "standard"}]

      assert MachineTypes.unknown(Map.put(document, "machine", "gone")) == ["#/machine"]
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
      newest = Apiary.Processes.TypeTemplates.newest("qory.software")
      changed = put_in(newest.document, ["stages", Access.at(0), "description"], "Changed.")
      {:ok, _version} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", changed)
      assert share_locked?()
    end
  end

  describe "create/2" do
    test "adds a type, with an instance.configure entry of the type after", %{scope: scope} do
      assert {:ok, %MachineType{name: "large", is_default: false}} =
               MachineTypes.create(scope, @large)

      assert names() == [{"standard", true}, {"large", false}]

      assert [%Entry{before: before, after: after_}] = entries()
      assert before == %{"machine_type" => nil}

      assert after_ == %{
               "machine_type" => Map.merge(spec(), %{"name" => "large", "default" => false})
             }
    end

    test "made the default, leaves the default before it no longer one", %{scope: scope} do
      assert {:ok, %MachineType{is_default: true}} =
               MachineTypes.create(scope, Map.put(@large, :is_default, true))

      assert names() == [{"standard", false}, {"large", true}]
    end

    test "refuses a reserved, invalid or taken name, and numbers out of bounds", %{scope: scope} do
      for {name, validation} <- [
            {"default", :reserved},
            {"Large", :format},
            {"1large", :format},
            {"large_x", :format},
            {String.duplicate("a", 65), :format}
          ] do
        assert {:error, changeset} = MachineTypes.create(scope, %{@large | name: name})
        assert {_, opts} = changeset.errors[:name], name
        assert opts[:validation] == validation, name
      end

      assert {:error, changeset} = MachineTypes.create(scope, %{@large | name: "standard"})
      assert {_, [constraint: :unique, constraint_name: _]} = changeset.errors[:name]

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

      assert {:ok, _} = MachineTypes.create(scope, %{@large | name: String.duplicate("a", 64)})
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
      assert MachineTypes.create(nil, @large) == {:error, :forbidden}

      assert names() == [{"standard", true}]
    end
  end

  describe "update/3 and make_default/2" do
    test "change the spec, never the name, each with an entry", %{scope: scope} do
      large = machine_type_fixture(@large)

      assert {:ok, updated} =
               MachineTypes.update(scope, large, %{"vcpus" => 8, "name" => "other"})

      assert {updated.name, updated.vcpus} == {"large", 8}

      assert {:ok, %MachineType{is_default: true}} = MachineTypes.make_default(scope, updated)
      assert names() == [{"standard", false}, {"large", true}]

      assert [first, second] = entries()
      assert first.before["machine_type"]["vcpus"] == 4
      assert first.after["machine_type"]["vcpus"] == 8
      assert second.after["machine_type"]["default"] == true
    end

    test "a type deleted since is not found", %{scope: scope} do
      large = machine_type_fixture(@large)
      Repo.delete!(large)
      assert MachineTypes.update(scope, large, %{"vcpus" => 8}) == {:error, :not_found}
      assert MachineTypes.make_default(scope, large) == {:error, :not_found}
    end
  end

  describe "delete/2" do
    test "deletes a type no workflow uses, with an entry", %{scope: scope} do
      large = machine_type_fixture(@large)
      assert {:ok, _} = MachineTypes.delete(scope, large)
      assert names() == [{"standard", true}]
      assert [%Entry{before: %{"machine_type" => %{"name" => "large"}}} = entry] = entries()
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
               {:error, {:in_use, [%{place: scope.workspace.name, workflow: "write-specs"}]}}

      assert MachineTypes.get("large")
    end
  end
end

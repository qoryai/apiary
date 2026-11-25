defmodule Apiary.Artifacts.DeliverySendTest do
  # The send of a run's change (`Apiary.Artifacts.Delivery`): a push of a delivered type
  # builds and checks its `change_request` entry, sends it at once for `end_of_run`, and
  # at an approval at a gate for `after_gate`; and a push whose artifact has a version for
  # a target of another adapter is refused (`Apiary.Artifacts.push/5`).
  # Not async: the store's root is the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Artifacts, Processes, QoryHarnessFixture}
  alias Apiary.Adapters.{ChangeRequest, Collection, Connection, Feed}
  alias Apiary.Artifacts.{Delivery, Version}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag :tmp_dir
  @moduletag needs: [:workflow_model, :factory]

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{scope: scope, workspace: workspace} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    collection = target_candidate!(work_item)
    target_id = Target.id_of(work_item.organisation_id, work_item.workspace_id, target(work_item))

    {:ok, _type} =
      Artifacts.create_type(scope, workspace, %{
        "name" => "pull-request",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object"}
      })

    kinds!(work_item.adapter_id, ["pull-request"])

    %{
      scope: scope,
      workspace: workspace,
      work_item: work_item,
      target_id: target_id,
      collection: collection
    }
  end

  defp target(work_item), do: WorkItem.target(work_item)

  defp kinds!(adapter_id, kinds) do
    {1, _rows} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter_id), set: [change_kinds: kinds])
  end

  # A live run of the work item, registered with the target `target_id`, with the access
  # level `ctx.access` in its documents (`write` unless given), on the work item's process
  # version, whose record delivers `pull-request` with `send` and `schema`.
  defp run!(ctx, send, schema \\ QoryHarnessFixture.pull_request_schema(), target_id \\ nil) do
    %{dispatch_run: run} =
      explore_run_fixture(ctx.work_item,
        state: :handed_over,
        run: %{
          target_id: target_id || ctx.target_id,
          run_documents: Jason.encode!(%{"access" => Map.get(ctx, :access, "write")})
        }
      )

    version = Processes.version_for(ctx.work_item)

    entry = %{
      "name" => "pull-request",
      "base_view" => "structured",
      "deliver" => %{"send" => send},
      "json_schema" => schema
    }

    template = %{"commit" => String.duplicate("a", 40), "artifact_types" => [entry]}

    {1, _rows} =
      Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
        set: [template: template]
      )

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [process_version_id: version.id]
      )

    Repo.get!(DispatchRun, run.id)
  end

  defp commit(n) do
    %{
      "collection" => "acme/shop",
      "address" => %{
        "system" => "forge.example.com",
        "path" => n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")
      }
    }
  end

  defp pull_request(changes \\ %{}) do
    Map.merge(
      %{
        "target" => %{
          "collection" => "acme/shop",
          "address" => %{"system" => "forge.example.com", "path" => "acme/shop"}
        },
        "title" => "Keep the sale price in the basket",
        "text" => "The basket keeps the sale price.",
        "commits" => [commit(1)],
        "head" => commit(1),
        "base" => commit(0),
        "branch" => "sale-price",
        "base_branch" => "main",
        "steps" => [],
        "draft" => true
      },
      changes
    )
  end

  defp push(ctx, run, document, work_item \\ nil) do
    Artifacts.push({:run, run}, work_item || ctx.work_item, "pull-request", [
      %{
        filename: "pull-request.json",
        content_type: "application/json",
        binary: Jason.encode!(document)
      }
    ])
  end

  defp stored(version), do: Repo.get!(Version, version.id)

  # The work item's collection assigned to no workspace, as a member leaves it.
  defp unassign!(ctx) do
    {1, _rows} =
      Repo.update_all(from(c in Collection, where: c.id == ^ctx.collection.id),
        set: [workspace_id: nil]
      )
  end

  # The connection of the work item's collection ended.
  defp disconnect!(ctx) do
    {1, _rows} =
      Repo.update_all(from(n in Connection, where: n.id == ^ctx.collection.connection_id),
        set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
      )
  end

  # The work item's collection ended, as a listing that leaves it out ends it.
  defp end_collection!(ctx) do
    {1, _rows} =
      Repo.update_all(from(c in Collection, where: c.id == ^ctx.collection.id),
        set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
      )
  end

  # The workspace's row of the work item's target deleted.
  defp delete_target!(ctx) do
    {1, _rows} = Repo.delete_all(from(t in Target, where: t.id == ^ctx.target_id))
  end

  # The workspace set to a domain other than software, written to the row directly:
  # `software` is the one domain in `Apiary.Lingo.Domain`.
  defp other_domain!(ctx) do
    {1, _rows} =
      Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
        set: [domain: "customer-care"]
      )
  end

  defp other_collection,
    do: pull_request(%{"target" => %{pull_request()["target"] | "collection" => "acme/other"}})

  defp adapter(ctx), do: Repo.get!(Node, ctx.work_item.adapter_id)
  defp entries(ctx), do: Feed.entries(adapter(ctx))

  # An approval at a gate that covers `versions`, under the work item's lock.
  defp approve!(ctx, versions) do
    {:ok, result} =
      Repo.transaction(fn ->
        held =
          Repo.one!(from w in WorkItem, where: w.id == ^ctx.work_item.id, lock: "FOR UPDATE")

        Delivery.approved(held, Enum.map(versions, & &1.public_id))
      end)

    result
  end

  # A target with a member the feed's entry does not have, in it and in its address.
  defp open_target do
    target = pull_request()["target"]
    %{target | "address" => Map.put(target["address"], "port", 443)} |> Map.put("kind", "branch")
  end

  # Content within the contract's bounds, 60,000 numbers of 8 bytes in JSON, which Postgres
  # writes in plain notation, about 300 bytes each, so its entry is over the feed's check.
  defp small_numbers do
    numbers = Map.new(10..69, &{"n#{&1}", List.duplicate(1.5e-300, 1000)})
    Map.put(numbers, "target", pull_request()["target"])
  end

  describe "end_of_run" do
    test "sends the entry when the version is stored, once, with the target's row", ctx do
      run = run!(ctx, "end_of_run")
      document = pull_request()

      assert {:ok, version} = push(ctx, run, document)

      assert %{delivery: :sent, delivery_target_id: target_id, delivery_at: %DateTime{}} =
               stored(version)

      assert target_id == ctx.target_id

      assert [%{kind: "change_request", data: data}] = entries(ctx)

      assert data == %{
               "change_request_id" => version.public_id,
               "change_kind" => "pull-request",
               "target" => document["target"],
               "ref" => ctx.work_item.external_ref,
               "title" => document["title"],
               "text" => document["text"],
               "data" => document
             }

      # An approval covers no sent version again.
      assert approve!(ctx, [version]) == :ok
      assert length(entries(ctx)) == 1
    end

    test "puts the previous title and the address the adapter reported in a later entry",
         ctx do
      run = run!(ctx, "end_of_run")
      assert {:ok, first} = push(ctx, run, pull_request())

      reply = %{"action" => "created", "address" => %{"url" => "https://forge.example.com/p/3"}}

      assert {:ok, :stored} =
               Delivery.delivered(ctx.work_item.adapter_id, %{
                 change_request_id: first.public_id,
                 collection: "acme/shop",
                 reply: reply
               })

      assert {:ok, second} = push(ctx, run, pull_request(%{"title" => "Keep the sale price"}))
      assert stored(second).delivery == :sent

      assert [_first, %{data: data}] = entries(ctx)
      assert data["change_request_id"] == second.public_id

      assert data["previous"] == %{
               "title" => "Keep the sale price in the basket",
               "address" => reply["address"]
             }
    end

    test "sends the newest 100 commits and counts those left out; the version keeps all",
         ctx do
      run = run!(ctx, "end_of_run")
      commits = Enum.map(1..140, &commit/1)
      document = pull_request(%{"commits" => commits, "head" => commit(140)})

      assert {:ok, version} = push(ctx, run, document)
      assert stored(version).delivery == :sent

      assert [%{data: %{"data" => data}}] = entries(ctx)
      assert data["commits"] == Enum.map(41..140, &commit/1)
      assert data["earlier_commits"] == 40

      [file] = Repo.preload(version, files: Artifacts.files_query()).files

      assert {:ok, %{"commits" => ^commits}} =
               Apiary.Stages.Artifacts.stored_json(%{files: [file]})
    end

    test "marks a version for another collection than the run's invalid at #/target", ctx do
      run = run!(ctx, "end_of_run")
      assert {:ok, version} = push(ctx, run, other_collection())

      assert %{delivery: :failed, delivery_failure: :invalid, delivery_detail: "#/target"} =
               stored(version)

      assert entries(ctx) == []
    end

    test "sends the run's target, whatever address the version has", ctx do
      run = run!(ctx, "end_of_run")
      target = pull_request()["target"]
      elsewhere = %{target | "address" => %{"system" => "other.example.com", "path" => "x/y"}}

      assert {:ok, version} = push(ctx, run, pull_request(%{"target" => elsewhere}))
      assert stored(version).delivery == :sent
      assert [%{data: %{"target" => ^target}}] = entries(ctx)
    end

    test "sends nothing for a run whose access level is not write", ctx do
      for access <- ["read", "write-no-push"] do
        run = run!(Map.put(ctx, :access, access), "end_of_run")
        assert {:ok, version} = push(ctx, run, pull_request())
        assert stored(version).delivery == nil
      end

      assert entries(ctx) == []
    end

    test "sends the change of a write run in a workspace of another domain", ctx do
      other_domain!(ctx)
      run = run!(ctx, "end_of_run")
      assert {:ok, version} = push(ctx, run, pull_request())
      assert stored(version).delivery == :sent
      assert [_entry] = entries(ctx)
    end

    test "sends nothing for a read run in a workspace of any domain", ctx do
      for domain! <- [fn _ctx -> :software end, &other_domain!/1] do
        domain!.(ctx)
        run = run!(Map.put(ctx, :access, "read"), "end_of_run")
        assert {:ok, version} = push(ctx, run, pull_request())
        assert stored(version).delivery == nil
      end

      assert entries(ctx) == []
    end

    test "marks target_removed for a collection no longer assigned or connected", ctx do
      for gone! <- [&unassign!/1, &disconnect!/1] do
        run = run!(ctx, "end_of_run")
        gone!.(ctx)
        assert {:ok, version} = push(ctx, run, pull_request())

        assert %{delivery: :failed, delivery_failure: :target_removed, delivery_target_id: nil} =
                 stored(version)

        # Assigned and connected again for the next case.
        {1, _rows} =
          Repo.update_all(from(n in Connection, where: n.id == ^ctx.collection.connection_id),
            set: [state: :connected, ended_at: nil, ended_reason: nil]
          )

        {1, _rows} =
          Repo.update_all(from(c in Collection, where: c.id == ^ctx.collection.id),
            set: [workspace_id: ctx.work_item.workspace_id]
          )
      end

      assert entries(ctx) == []
    end

    test "marks target_removed for an ended collection", ctx do
      run = run!(ctx, "end_of_run")
      end_collection!(ctx)
      assert {:ok, version} = push(ctx, run, pull_request())
      assert %{delivery: :failed, delivery_failure: :target_removed} = stored(version)
      assert entries(ctx) == []
    end

    test "marks target_removed for a workspace with no row of the target", ctx do
      run = run!(ctx, "end_of_run")
      delete_target!(ctx)
      assert {:ok, version} = push(ctx, run, pull_request())

      assert %{delivery: :failed, delivery_failure: :target_removed, delivery_target_id: nil} =
               stored(version)

      assert entries(ctx) == []
    end

    test "sends nothing to an adapter whose source lacks the kind", ctx do
      for kinds <- [nil, ["reply"]] do
        kinds!(ctx.work_item.adapter_id, kinds)
        run = run!(ctx, "end_of_run")

        assert {:ok, version} = push(ctx, run, pull_request())
        assert stored(version).delivery == nil
      end

      assert entries(ctx) == []
    end

    test "sends the target's collection and address alone, and keeps the rest in data",
         ctx do
      run = run!(ctx, "end_of_run", %{"type" => "object"})
      document = pull_request(%{"target" => open_target()})

      assert {:ok, version} = push(ctx, run, document)
      assert stored(version).delivery == :sent
      assert [%{data: data}] = entries(ctx)
      assert data["target"] == pull_request()["target"]
      assert data["data"]["target"] == open_target()
    end

    test "marks an entry over the feed's bound as jsonb text invalid, and sends nothing",
         ctx do
      run = run!(ctx, "end_of_run", %{"type" => "object"})
      assert byte_size(Jason.encode!(small_numbers())) < ChangeRequest.max_data()

      assert {:ok, version} = push(ctx, run, small_numbers())

      assert %{delivery: :failed, delivery_failure: :invalid, delivery_detail: "#/data"} =
               stored(version)

      assert entries(ctx) == []
    end

    test "sends nothing to an adapter that lacks the kind, with its collection gone", ctx do
      kinds!(ctx.work_item.adapter_id, ["reply"])
      unassign!(ctx)
      run = run!(ctx, "end_of_run")

      assert {:ok, version} = push(ctx, run, pull_request())
      assert stored(version).delivery == nil
      assert entries(ctx) == []
    end

    test "sends with no previous title when the previous version's file cannot be read",
         ctx do
      run = run!(ctx, "end_of_run")
      assert {:ok, first} = push(ctx, run, pull_request())
      assert stored(first).delivery == :sent

      Application.put_env(:apiary, :artifacts_dir, Path.join(ctx.tmp_dir, "elsewhere"))

      log =
        capture_log(fn ->
          assert {:ok, second} = push(ctx, run, pull_request())
          assert stored(second).delivery == :sent
        end)

      assert log =~ "previous version unreadable"
      assert [_first, %{data: data}] = entries(ctx)
      refute Map.has_key?(data, "previous")
    end

    test "builds no entry for a version with no target", ctx do
      run = run!(ctx, "end_of_run", %{"type" => "object"})

      assert {:ok, version} = push(ctx, run, %{"title" => "A change with no target"})
      assert stored(version).delivery == nil
      assert entries(ctx) == []
    end
  end

  describe "after_gate" do
    test "sends nothing before the gate, and the covered version at the approval", ctx do
      run = run!(ctx, "after_gate")

      assert {:ok, version} = push(ctx, run, pull_request())
      assert stored(version).delivery == nil
      assert entries(ctx) == []

      # An approval that covers other versions sends nothing.
      assert approve!(ctx, []) == :ok
      assert entries(ctx) == []

      assert approve!(ctx, [version]) == :ok
      assert %{delivery: :sent, delivery_target_id: target_id} = stored(version)
      assert target_id == ctx.target_id
      assert [%{kind: "change_request", data: %{"change_request_id" => id}}] = entries(ctx)
      assert id == version.public_id

      # A second approval sends it once.
      assert approve!(ctx, [version]) == :ok
      assert length(entries(ctx)) == 1
    end

    test "marks an invalid entry at the store, before any gate", ctx do
      run = run!(ctx, "after_gate", %{"type" => "object"})

      assert {:ok, version} = push(ctx, run, %{"target" => %{"collection" => ""}})
      assert %{delivery: :failed, delivery_failure: :invalid} = stored(version)

      assert approve!(ctx, [version]) == :ok
      assert entries(ctx) == []
    end

    test "sends the target's collection and address alone at the approval", ctx do
      run = run!(ctx, "after_gate", %{"type" => "object"})
      assert {:ok, version} = push(ctx, run, pull_request(%{"target" => open_target()}))
      assert stored(version).delivery == nil

      assert approve!(ctx, [version]) == :ok
      assert stored(version).delivery == :sent
      assert [%{data: %{"target" => target}}] = entries(ctx)
      assert target == pull_request()["target"]
    end

    test "marks an entry over the feed's bound as jsonb text invalid at the store", ctx do
      run = run!(ctx, "after_gate", %{"type" => "object"})
      assert {:ok, version} = push(ctx, run, small_numbers())

      assert %{delivery: :failed, delivery_failure: :invalid, delivery_detail: "#/data"} =
               stored(version)

      assert approve!(ctx, [version]) == :ok
      assert entries(ctx) == []
    end

    test "skips a withdrawn version and a version with no target", ctx do
      run = run!(ctx, "after_gate", %{"type" => "object"})
      assert {:ok, withdrawn} = push(ctx, run, pull_request())

      {1, _rows} =
        Repo.update_all(from(v in Version, where: v.id == ^withdrawn.id), set: [withdrawn: true])

      assert {:ok, no_target} =
               Artifacts.push(
                 {:run, run},
                 ctx.work_item,
                 "pull-request",
                 [
                   %{
                     filename: "pull-request.json",
                     content_type: "application/json",
                     binary: Jason.encode!(%{"title" => "A change with no target"})
                   }
                 ],
                 name: "other"
               )

      assert approve!(ctx, [withdrawn, no_target]) == :ok
      assert stored(withdrawn).delivery == nil
      assert stored(no_target).delivery == nil
      assert entries(ctx) == []
    end

    test "marks target_removed at the approval for a collection unassigned after the push",
         ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())
      assert stored(version).delivery == nil

      unassign!(ctx)
      assert approve!(ctx, [version]) == :ok
      assert %{delivery: :failed, delivery_failure: :target_removed} = stored(version)
      assert entries(ctx) == []
    end

    test "marks target_removed at the approval for a connection ended after the push", ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      disconnect!(ctx)
      assert approve!(ctx, [version]) == :ok
      assert %{delivery: :failed, delivery_failure: :target_removed} = stored(version)
      assert entries(ctx) == []
    end

    test "marks target_removed at the approval for a collection ended after the push", ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      end_collection!(ctx)
      assert approve!(ctx, [version]) == :ok
      assert %{delivery: :failed, delivery_failure: :target_removed} = stored(version)
      assert entries(ctx) == []
    end

    test "marks target_removed at the approval for a target row deleted after the push",
         ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      delete_target!(ctx)
      assert approve!(ctx, [version]) == :ok
      assert %{delivery: :failed, delivery_failure: :target_removed} = stored(version)
      assert entries(ctx) == []
    end

    test "sends nothing at the approval for a run whose access level is not write", ctx do
      run = run!(Map.put(ctx, :access, "read"), "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      assert approve!(ctx, [version]) == :ok
      assert stored(version).delivery == nil
      assert entries(ctx) == []
    end

    test "sends at the approval the change of a write run in a workspace of another domain",
         ctx do
      other_domain!(ctx)
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      assert approve!(ctx, [version]) == :ok
      assert stored(version).delivery == :sent
      assert [_entry] = entries(ctx)
    end

    test "marks a version for another collection invalid at the store", ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, other_collection())
      assert %{delivery: :failed, delivery_detail: "#/target"} = stored(version)

      assert approve!(ctx, [version]) == :ok
      assert entries(ctx) == []
    end

    test "fails the approval when the version's file cannot be read", ctx do
      run = run!(ctx, "after_gate")
      assert {:ok, version} = push(ctx, run, pull_request())

      Application.put_env(:apiary, :artifacts_dir, Path.join(ctx.tmp_dir, "elsewhere"))
      assert approve!(ctx, [version]) == {:error, :store_unavailable}
      assert stored(version).delivery == nil
    end
  end

  describe "the collection of a target" do
    test "fails a push whose artifact has a version for a target of another adapter",
         ctx do
      first = run!(ctx, "after_gate")
      assert {:ok, waiting} = push(ctx, first, pull_request())
      assert stored(waiting).delivery == nil

      # The work item's target moves to a collection of another adapter with the same ref.
      other = work_item_fixture(ctx.scope)
      assert other.adapter_id != ctx.work_item.adapter_id

      # The connection goes too, and the ticket and the ref: the ticket is of the first
      # adapter, and the other work item has the same ref at the other adapter.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            adapter_id: other.adapter_id,
            connection_id: other.connection_id,
            external_ref: "acme/shop#moved",
            item_id: nil
          ]
        )

      moved = Repo.get!(WorkItem, ctx.work_item.id)
      other_target = Target.id_of(moved.organisation_id, moved.workspace_id, target(moved))

      second =
        run!(
          %{ctx | work_item: moved},
          "after_gate",
          QoryHarnessFixture.pull_request_schema(),
          other_target
        )

      assert push(ctx, second, pull_request(), moved) == {:error, :collection_clash}

      assert Repo.aggregate(
               from(v in Version, where: v.artifact_id == ^waiting.artifact_id),
               :count
             ) ==
               1

      # Back on the first adapter, a run's push is not refused.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            adapter_id: ctx.work_item.adapter_id,
            connection_id: ctx.work_item.connection_id,
            external_ref: ctx.work_item.external_ref,
            item_id: ctx.work_item.item_id
          ]
        )

      assert {:ok, _version} = push(ctx, first, pull_request())
    end
  end
end

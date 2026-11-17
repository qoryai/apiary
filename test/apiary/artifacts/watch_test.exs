defmodule Apiary.Artifacts.WatchTest do
  # The `watch` entry that `Apiary.Artifacts.push/5` writes for a run's submission
  # version: one per version a run stores of the type in `submit.type` of its process
  # version, in the feed of the adapter of the work item's target collection, and none for
  # any other version, writer or work item. Not async: the store's root is the
  # application's setting.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, WorkItems}
  alias Apiary.Adapters.{Collection, Connection, Feed}
  alias Apiary.Artifacts.{Type, Version}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.Version, as: ProcessVersion

  @moduletag :tmp_dir
  @moduletag needs: [:workflow_model, :factory]

  # The run's submission type, a structured type that the setup adds to the workspace.
  @submit %{"type" => "submission", "send" => "end_of_run"}
  @commit String.duplicate("a", 40)

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    scope = without_template_types(scope_fixture())
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item, state: :handed_over)
    source = Repo.get!(Node, Repo.get!(Connection, work_item.connection_id).adapter_id)

    {:ok, _type} =
      Artifacts.create_type(scope, scope.workspace, %{
        "name" => "submission",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object", "required" => ["summary"]}
      })

    %{scope: scope, work_item: work_item, run: run, source: source}
  end

  # A sign-up's workspace has the Qory template's types. These tests start from a workspace
  # with no list and no custom type, so every standard type is shown.
  defp without_template_types(%{workspace: %{id: id}} = scope) do
    Repo.delete_all(from t in Type, where: t.workspace_id == ^id)
    Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [shown_standard_types: nil])
    %{scope | workspace: Repo.get!(Workspace, id)}
  end

  # The run's process version saved with `submit` in its template, nil for none.
  defp submits!(%{scope: scope, run: run}, submit) do
    {:ok, version} =
      Apiary.Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => "st_r79kph11eg",
            "name" => "Explore",
            "inputs" => [],
            "sequence" => [%{"workflow" => "explore-a-ticket"}],
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      })

    template = %{"commit" => @commit}
    template = if submit, do: Map.put(template, "submit", submit), else: template

    {1, _rows} =
      Repo.update_all(from(v in ProcessVersion, where: v.id == ^version.id),
        set: [template: template]
      )

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [process_version_id: version.id]
      )
  end

  # A collection of a new adapter of the instance whose target is the work item's, its
  # adapter's collections with targets, as a code forge's are. Returns the adapter.
  defp forge!(%{scope: scope, work_item: work_item}) do
    collection =
      collection_fixture(scope,
        target_system: work_item.target_system,
        target_path: work_item.target_path
      )

    {1, _rows} =
      Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
        set: [targets: true]
      )

    Repo.get!(Node, collection.adapter_id)
  end

  defp doc, do: %{filename: "notes.md", content_type: "text/markdown", binary: "# Notes"}

  # A version of the submission, `summary` its one member.
  defp submission(summary \\ "The basket keeps the sale price."),
    do: [
      %{
        filename: "submission.json",
        content_type: "application/json",
        binary: Jason.encode!(%{"summary" => summary})
      }
    ]

  defp watch(work_item) do
    %{
      kind: "watch",
      data: %{"work_item_id" => work_item.public_id, "url" => WorkItems.stable_url(work_item)}
    }
  end

  defp entries(adapter), do: Enum.map(Feed.entries(adapter), &Map.take(&1, [:kind, :data]))

  test "a run storing a submission version adds a watch entry to the target's adapter", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    assert {:ok, %Version{number: 1}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

    assert [%{seq: 1} = entry] = Feed.entries(forge)
    assert Map.take(entry, [:kind, :data]) == watch(ctx.work_item)
    assert entry.data["work_item_id"] =~ ~r/\Awi_/
    # The source's adapter, another adapter here, gets no entry.
    assert Feed.entries(ctx.source) == []
  end

  test "two versions add two entries", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    assert {:ok, %Version{number: 1}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission("a"))

    assert {:ok, %Version{number: 2}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission("b"))

    assert entries(forge) == [watch(ctx.work_item), watch(ctx.work_item)]
    assert Enum.map(Feed.entries(forge), & &1.seq) == [1, 2]
  end

  test "a version of another type adds no entry", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    assert {:ok, %Version{}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])

    assert Feed.entries(forge) == []
  end

  test "a person's version of the submission type adds no entry", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    assert {:ok, %Version{writer: :person}} =
             Artifacts.push({:person, ctx.scope}, ctx.work_item, "submission", submission())

    assert Feed.entries(forge) == []
  end

  test "a run whose process version has no submit adds no entry", ctx do
    submits!(ctx, nil)
    forge = forge!(ctx)

    assert {:ok, %Version{}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

    assert Feed.entries(forge) == []
  end

  test "a run with no process version adds no entry", ctx do
    forge = forge!(ctx)

    assert {:ok, %Version{}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

    assert Feed.entries(forge) == []
  end

  test "a target that no collection matches stores the version with no entry", ctx do
    submits!(ctx, @submit)

    # A collection with targets, of another target path.
    other =
      collection_fixture(ctx.scope,
        target_system: ctx.work_item.target_system,
        target_path: "acme/other"
      )

    Repo.update_all(from(n in Node, where: n.id == ^other.adapter_id), set: [targets: true])
    # A collection with the work item's target, of an adapter whose collections have none.
    plain =
      collection_fixture(ctx.scope,
        target_system: ctx.work_item.target_system,
        target_path: ctx.work_item.target_path
      )

    assert {:ok, %Version{number: 1}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

    for adapter_id <- [other.adapter_id, plain.adapter_id, ctx.source.id] do
      assert Feed.entries(Repo.get!(Node, adapter_id)) == []
    end

    assert Repo.aggregate(from(f in "adapter_feed"), :count) == 0
  end

  test "a work item with no target stores the version with no entry", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    {1, _rows} =
      Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^ctx.work_item.id),
        set: [target_system: nil, target_path: nil]
      )

    work_item = Repo.get!(Apiary.WorkItems.WorkItem, ctx.work_item.id)

    assert {:ok, %Version{number: 1}} =
             Artifacts.push({:run, ctx.run}, work_item, "submission", submission())

    assert Feed.entries(forge) == []
  end

  test "the entry goes to the source's adapter when its collection is the target's", ctx do
    submits!(ctx, @submit)
    forge!(ctx)
    # The ticket's collection made one with the work item's target; the run takes it before
    # another with the same target (`Apiary.Runs.RunCredentials`).
    %Collection{adapter_id: adapter_id} = target_candidate!(ctx.work_item)
    assert adapter_id == ctx.source.id

    assert {:ok, %Version{}} =
             Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

    assert entries(ctx.source) == [watch(ctx.work_item)]
  end

  test "the entry commits with its version: rolled back, neither is there", ctx do
    submits!(ctx, @submit)
    forge = forge!(ctx)

    assert {:error, :undone} =
             Repo.transaction(fn ->
               {:ok, %Version{}} =
                 Artifacts.push({:run, ctx.run}, ctx.work_item, "submission", submission())

               assert [%{kind: "watch"}] = Feed.entries(forge)
               Repo.rollback(:undone)
             end)

    assert Feed.entries(forge) == []
    assert Repo.aggregate(Version, :count) == 0
  end
end

defmodule ApiaryWeb.RunLive.ShowSubmissionTest do
  @moduledoc """
  The Submission block of a run's page, under the version list of Save the outputs: the
  row of the version of the submission type that the run stored (`Apiary.Submissions`),
  with its commits, and none for a run whose process version names no submit type. Not
  async: the store's root is the application's setting.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [with_domain: 2]
  import Apiary.RunEventsFixtures

  alias Apiary.{Artifacts, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Processes.Version, as: ProcessVersion
  alias Apiary.Runs.Projector
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @head String.duplicate("a1", 20)
  @base String.duplicate("9f", 20)
  @change String.duplicate("4c", 20)

  setup :register_and_log_in_user

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)
    :ok
  end

  defp run_path(scope, run), do: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

  # A run handed over, with its session started, and the process version it runs under
  # saved with `submit` in its template (nil for none).
  defp handed_over!(ctx, submit) do
    pool = Apiary.NodesFixtures.pool_fixture(ctx.scope, name: "build-pool")
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

    %{run: run, dispatch_run: dispatch_run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(ctx.scope, key)

    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    version = Apiary.Processes.version_for(work_item)
    template = %{"commit" => String.duplicate("a", 40)}
    template = if submit, do: Map.put(template, "submit", submit), else: template

    {1, _rows} =
      Repo.update_all(from(v in ProcessVersion, where: v.id == ^version.id),
        set: [template: template]
      )

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [process_version_id: version.id]
      )

    # The workspace's `submission` type, with a schema that takes any object.
    Repo.delete_all(
      from t in Apiary.Artifacts.Type,
        where: t.workspace_id == ^work_item.workspace_id and t.name == "submission"
    )

    {:ok, _type} =
      Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
        "name" => "submission",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object"}
      })

    events = [
      {1, "run.started", started_data()},
      {4, "session.started", session_started_data()},
      {5, "runtime.started", %{"session_id" => "session-0001"}}
    ]

    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    %{run: run, dispatch_run: Repo.reload!(dispatch_run), work_item: work_item}
  end

  defp store!(%{dispatch_run: dispatch_run, work_item: work_item}, value) do
    file = %{
      filename: "submission.json",
      content_type: "application/json",
      binary: Jason.encode!(value)
    }

    {:ok, version} = Artifacts.push({:run, dispatch_run}, work_item, "submission", [file])
    version
  end

  defp submission do
    %{
      "ref" => "qory/wi_qk5p97dt9vdq39a2",
      "verdict" => "passed",
      "repositories" => [
        %{
          "system" => "git.example.com",
          "path" => "northwind/storefront",
          "commit" => @head,
          "commit_url" => "https://git.example.com/northwind/storefront/commit/#{@head}",
          "base" => %{"commit" => @base},
          "commits" => [
            %{"commit" => @change, "step" => "deliverable:d-2"},
            %{"commit" => @head, "step" => "fix:f1"}
          ],
          "draft" => %{
            "number" => 34,
            "url" => "https://git.example.com/northwind/storefront/pulls/34",
            "title" => "Show delivery dates at checkout",
            "state" => "draft",
            "action" => "opened"
          }
        }
      ]
    }
  end

  test "Save the outputs has the Submission block under the version list", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)
    store!(run_ctx, submission())

    {:ok, lv, _html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))

    block = "#prepare-machine-session-outputs-submission-1"
    assert has_element?(lv, "#prepare-machine-session-outputs dd", "Version 1")
    assert has_element?(lv, "#{block}-row", "Submission v1")
    assert has_element?(lv, "#{block}-row-r0-branch", "qory/wi_qk5p97dt9vdq39a2")
    assert has_element?(lv, "#{block}-row-r0-branch a", "a1a1a1a")
    assert has_element?(lv, "#{block}-row-r0-base", "9f9f9f9")
    assert has_element?(lv, "#{block}-row-r0-base", "Base: where the branch starts")
    assert has_element?(lv, "#{block}-row-r0-c0", "4c4c4c4")
    assert has_element?(lv, "#{block}-row-r0-c1", "Fix of review finding f1")
    assert has_element?(lv, "#{block}-row-r0-c1 .badge", "Head")
    assert has_element?(lv, "#{block}-row-r0-draft", "#34 “Show delivery dates at checkout”")
    assert has_element?(lv, "#{block}-row-r0-fold[open]")
  end

  test "a version the run stores while the page is open reaches the block at once", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)

    {:ok, lv, _html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))
    refute has_element?(lv, "#prepare-machine-session-outputs")

    store!(run_ctx, submission())

    assert has_element?(lv, "#prepare-machine-session-outputs-submission-1-row", "Submission v1")
  end

  test "a run whose process version has no submit type has no block", ctx do
    run_ctx = handed_over!(ctx, nil)
    store!(run_ctx, submission())

    {:ok, lv, _html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))

    assert has_element?(lv, "#prepare-machine-session-outputs dd", "Version 1")
    refute has_element?(lv, "#prepare-machine-session-outputs-submission-1")
  end

  test "a version of another type has no block", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)

    {:ok, _type} =
      Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
        "name" => "notes",
        "base_view" => "document",
        "size_limit" => 1000,
        "max_files" => 1
      })

    file = %{filename: "notes.md", content_type: "text/markdown", binary: "# Notes\n"}

    {:ok, _version} =
      Artifacts.push({:run, run_ctx.dispatch_run}, run_ctx.work_item, "notes", [file])

    {:ok, lv, _html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))

    assert has_element?(lv, "#prepare-machine-session-outputs dd", "Version 1")
    refute has_element?(lv, "#prepare-machine-session-outputs-submission-1")
  end

  test "a stored string is shown as text", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)

    value =
      update_in(submission(), ["repositories", Access.at(0), "draft", "title"], fn _title ->
        "<script>alert(1)</script>"
      end)

    store!(run_ctx, value)

    {:ok, lv, html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))

    assert has_element?(
             lv,
             "#prepare-machine-session-outputs-submission-1-row-r0-draft",
             "<script>"
           )

    refute html =~ "<script>alert(1)"
  end

  # A second version of the same run, whose base is the first version's head.
  defp second_version(value) do
    update_in(value, ["repositories", Access.at(0)], fn repository ->
      %{repository | "base" => %{"commit" => @head}}
    end)
  end

  defp block_words(lv, number) do
    lv
    |> element("#prepare-machine-session-outputs-submission-#{number}-row")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
  end

  test "a software workspace reads Branch, Commits, Head and the head of the run", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)
    store!(run_ctx, submission())
    store!(run_ctx, second_version(submission()))

    {:ok, lv, _html} = live(ctx.conn, run_path(ctx.scope, run_ctx.run))

    words = block_words(lv, 2)
    assert words =~ "Branch"
    assert words =~ "Commits"
    assert words =~ "Base: the head of Run #{run_ctx.run.number}"
    assert words =~ "Head"
    refute words =~ "Latest"
    refute words =~ "Reference"
    refute words =~ "Revisions"
    refute words =~ "the result of Run"
  end

  test "a workspace that is not a software factory reads the engine's words", ctx do
    submit = %{"type" => "submission", "send" => "end_of_run"}
    run_ctx = handed_over!(ctx, submit)
    store!(run_ctx, submission())
    store!(run_ctx, second_version(submission()))
    scope = with_domain(ctx.scope, "example")

    {:ok, lv, _html} = live(ctx.conn, run_path(scope, run_ctx.run))

    words = block_words(lv, 2)
    assert words =~ "Reference"
    assert words =~ "Revisions"
    assert words =~ "Base: the result of Run #{run_ctx.run.number}"
    assert words =~ "Latest"
    refute words =~ "Branch"
    refute words =~ "Commits"
    refute words =~ "Head"
    refute words =~ "the head of Run"
    refute words =~ "commit"

    assert block_words(lv, 1) =~ "Base: where the work starts"
  end
end

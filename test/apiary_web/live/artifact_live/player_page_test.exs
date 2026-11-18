defmodule ApiaryWeb.ArtifactLive.PlayerPageTest do
  # The page of a scenario's film or pictures (`ApiaryWeb.ArtifactLive.Show`) as a player
  # page: the scenario's title and steps under the player, the work item's scenarios as a
  # queue in the right column, in the order of the Verify tab, a click on one opening that
  # scenario's page. A version in no scenario has no queue and no scenario section.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.WorkItemLive.VerifyTab
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @verify "st_m1mqbeywdg"

  @commit String.duplicate("c", 40)

  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  @verification """
  ## Summary

  Commit: #{@commit}. One criterion is met.

  ## Matrix

  | Criterion | State | Evidence |
  |---|---|---|
  | AC-1, "After a reload, the total still includes the voucher" | Met | Demo video: scenario 1 |

  ## Model families

  Build: claude. Verify: deepseek.
  """

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope} do
    for {name, view} <- [
          {"verification", "document"},
          {"demo-evidence", "file"},
          {"demo-script", "file"}
        ] do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => name, "base_view" => view})
    end

    [explore | _rest] = Processes.default_document("software")["stages"]
    gate = %{"kind" => "person", "approvers" => "members"}
    output = &%{"type" => &1, "required" => false}

    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "stages" => [
          explore,
          %{"id" => @shape, "name" => "Shape", "sequence" => [], "outputs" => [], "gate" => gate},
          %{
            "id" => @verify,
            "name" => "Verify",
            "sequence" => [%{"workflow" => "verify-a-ticket"}],
            "outputs" =>
              Enum.map(
                ~w(verification demo-video screenshot demo-evidence explainer),
                output
              ),
            "gate" => gate
          }
        ]
      })

    :ok
  end

  # A work item at Verify's gate, whose run of Verify pushed what `push` pushes.
  defp at_verify_gate!(scope, push) do
    {:ok, work_item} = WorkItems.take_in(scope, backlog_ticket_fixture(scope).public_id)
    work_item = Repo.get!(WorkItem, work_item.id) |> end_run!(understood_result())
    {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
    work_item = Repo.get!(WorkItem, work_item.id)
    {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

    work_item =
      work_item
      |> then(&Repo.get!(WorkItem, &1.id))
      |> end_run!(fn run, _registered ->
        push.(run, Repo.get!(WorkItem, run.work_item_id))

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed"},
            stage_id: run.stage_id
          )
      end)

    assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
    work_item
  end

  defp push!(run, work_item, type, name, files) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        type,
        for(
          {filename, binary} <- files,
          do: %{filename: filename, content_type: "application/octet-stream", binary: binary}
        ),
        name: name,
        stage_id: run.stage_id
      )

    version
  end

  defp film_files(name),
    do: [
      {"#{name}.mp4", @mp4},
      {"#{name}.vtt", "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOpen\n"}
    ]

  defp picture_files(name),
    do: [{"#{name}-step-2.png", @png}, {"#{name}-step-1.png", @png}, {"#{name}-step-3.png", @png}]

  # A scenario's film or pictures, and its demo evidence.
  defp scenario!(run, work_item, n, kind) do
    name = "scenario-#{n}"
    titles = ["Open #{name}", "Reload #{name}", "Read #{name}"]

    {type, files} =
      case kind do
        :film -> {"demo-video", film_files(name)}
        :pictures -> {"screenshot", picture_files(name)}
      end

    media = push!(run, work_item, type, name, files)

    evidence = %{
      "scenario" => name,
      "title" => "Title of #{name}",
      "commit" => @commit,
      "verdict" => "passed",
      "media" => %{"type" => type, "name" => name, "version" => media.number},
      "steps" =>
        for(
          {title, i} <- Enum.with_index(titles, 1),
          do: %{"step" => i, "title" => title, "expected" => "Result #{i} of #{title}."}
        )
    }

    push!(run, work_item, "demo-evidence", name, [{"#{name}.json", Jason.encode!(evidence)}])
    media
  end

  # A work item at Verify's gate with scenario 1 (a film), 2 (pictures) and 10 (a film).
  defp three_scenarios!(scope) do
    at_verify_gate!(scope, fn run, work_item ->
      push!(run, work_item, "verification", "main", [{"verification.md", @verification}])
      scenario!(run, work_item, 10, :film)
      scenario!(run, work_item, 2, :pictures)
      scenario!(run, work_item, 1, :film)
    end)
  end

  # The queue as the page reads it: from the artifacts without a withdrawn name.
  defp queue(work_item) do
    artifacts = work_item |> Artifacts.list() |> Enum.reject(&Artifacts.withdrawn?/1)
    VerifyTab.queue(work_item, artifacts, @verify, work_item.take_in)
  end

  defp page(conn, scope, work_item, scenario) do
    {:ok, view, _html} =
      live(
        conn,
        ArtifactComponents.version_path(scope, work_item.number, scenario.version.public_id)
      )

    view
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "the queue" do
    test "lists the scenarios in the order of the Verify tab, the current one marked",
         %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first, second, tenth] = queue(work_item)
      view = page(conn, scope, work_item, second)

      assert has_element?(view, "#artifact-queue-title", "Scenarios")
      assert has_element?(view, "#artifact-queue-title", "2 of 3")

      assert texts(view, "#artifact-queue li a > span > span:first-child") == [
               "Scenario 1: Title of scenario-1",
               "Scenario 2: Title of scenario-2",
               "Scenario 10: Title of scenario-10"
             ]

      assert [first_item, second_item, tenth_item] =
               for(
                 scenario <- [first, second, tenth],
                 do: "#artifact-queue-item-#{scenario.key}"
               )

      # The current item is marked; the others link to their page.
      assert has_element?(view, ~s(#{second_item} a[aria-current="page"].bg-base-200))
      assert has_element?(view, "#{second_item} span.font-medium")
      assert [_only_one] = texts(view, ~s(#artifact-queue [aria-current="page"]))
      refute has_element?(view, "#artifact-queue", "Playing")

      for {item, scenario} <- [{first_item, first}, {tenth_item, tenth}] do
        path =
          ArtifactComponents.version_path(scope, work_item.number, scenario.version.public_id)

        assert has_element?(view, ~s(#{item} a[href="#{path}"]))
        refute has_element?(view, "#{item} a[aria-current]")
      end
    end

    test "has the first picture of a pictures scenario, and its count",
         %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first, second, _tenth] = queue(work_item)
      view = page(conn, scope, work_item, first)

      item = "#artifact-queue-item-#{second.key}"
      [picture | _more] = VerifyTab.pictures(second)
      {file, _step, 1} = picture
      src = ArtifactComponents.file_path(scope, work_item.number, second.version.public_id, file)

      assert has_element?(view, ~s(#{item} img[src="#{src}"]))
      assert has_element?(view, item, "3 pictures")
    end

    test "has a muted thumbnail of the film, the length filled in by the browser",
         %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first | _more] = queue(work_item)
      view = page(conn, scope, work_item, first)
      item = "#artifact-queue-item-#{first.key}"

      assert has_element?(view, "#{item}[phx-hook=QueueMedia] video[muted][preload=metadata]")
      assert has_element?(view, ~s(#{item} video[src$="/files/scenario-1.mp4#t=0.1"]))
      refute has_element?(view, "#{item} video[controls]")
      assert has_element?(view, ~s(#{item} [data-length="Demo video · %{length}"]))
    end

    test "a click on an item opens that scenario's page", %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first, second, _tenth] = queue(work_item)
      view = page(conn, scope, work_item, first)

      view |> element("#artifact-queue-item-#{second.key} a") |> render_click()

      assert_redirect(
        view,
        ArtifactComponents.version_path(scope, work_item.number, second.version.public_id)
      )
    end

    test "is read again when a version is pushed", %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first | _more] = queue(work_item)
      view = page(conn, scope, work_item, first)
      assert has_element?(view, "#artifact-queue-title", "1 of 3")

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &%{&1 | queue: [], scenario: nil})
      end)

      send(view.pid, {:artifact_pushed, work_item.public_id, first.version.public_id})
      assert has_element?(view, "#artifact-queue-title", "1 of 3")
    end
  end

  describe "the scenario under the player" do
    test "has the scenario's title and its steps with their expected results",
         %{conn: conn, scope: scope} do
      work_item = three_scenarios!(scope)
      [first | _more] = queue(work_item)
      view = page(conn, scope, work_item, first)

      assert has_element?(view, "#artifact-scenario-title", "Scenario 1: Title of scenario-1")

      assert texts(view, "#artifact-scenario li") == [
               "Step 1: Open scenario-1 Expected: Result 1 of Open scenario-1.",
               "Step 2: Reload scenario-1 Expected: Result 2 of Reload scenario-1.",
               "Step 3: Read scenario-1 Expected: Result 3 of Read scenario-1."
             ]

      # Under the player and above Files, in the left column; the queue is in the right one.
      assert has_element?(view, ".q-art-main #artifact-view-part")
      assert has_element?(view, ".q-art-main #artifact-scenario")
      assert has_element?(view, ".q-art-main #artifact-files-part")
      assert has_element?(view, "aside #artifact-queue")
      refute has_element?(view, "aside #artifact-scenario")
    end
  end

  describe "a version in no scenario" do
    test "has no queue and no scenario section", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          push!(run, work_item, "verification", "main", [{"verification.md", @verification}])
          scenario!(run, work_item, 1, :film)
          # A newer film that the demo evidence does not name.
          push!(run, work_item, "demo-video", "scenario-1", film_files("scenario-1"))
        end)

      [first] = queue(work_item)
      assert first.version.number == 1

      newer =
        Artifacts.list(work_item)
        |> Enum.find(&(&1.type == "demo-video"))
        |> then(& &1.versions)
        |> Enum.find(&(&1.number == 2))

      {:ok, view, _html} =
        live(
          conn,
          ArtifactComponents.version_path(scope, work_item.number, newer.public_id)
        )

      refute has_element?(view, "#artifact-queue")
      refute has_element?(view, "#artifact-scenario")
      assert has_element?(view, "#artifact-view-part video")
    end

    test "is not queued once its name is withdrawn", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          push!(run, work_item, "verification", "main", [{"verification.md", @verification}])
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film)

          for type <- ["demo-video", "demo-evidence"] do
            {:ok, _withdrawal} =
              Artifacts.withdraw({:run, run}, work_item, type,
                name: "scenario-2",
                stage_id: run.stage_id
              )
          end
        end)

      assert [first] = queue(work_item)
      view = page(conn, scope, work_item, first)

      assert has_element?(view, "#artifact-queue-title", "1 of 1")
      refute has_element?(view, "#artifact-queue-item-scenario-2")
    end

    test "is a page with no queue for a film the Verify stage did not make",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          push!(run, work_item, "verification", "main", [{"verification.md", @verification}])
          push!(run, work_item, "explainer", "main", [{"explainer.md", "Words."}])
        end)

      explainer = Artifacts.list(work_item) |> Enum.find(&(&1.type == "explainer"))

      {:ok, view, _html} =
        live(
          conn,
          ArtifactComponents.version_path(
            scope,
            work_item.number,
            hd(explainer.versions).public_id
          )
        )

      refute has_element?(view, "#artifact-queue")
      refute has_element?(view, "#artifact-scenario")
    end
  end
end

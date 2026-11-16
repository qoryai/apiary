defmodule ApiaryWeb.WorkItemLive.VerifyTabTest do
  # The tab of a stage with a `verification` output (`ApiaryWeb.WorkItemLive.VerifyTab`):
  # the matrix of the acceptance criteria with their states and evidence, the "not
  # verified" list, the model families, the member who accepted the stage's escalation, and
  # one Scenarios frame with each scenario's film or pictures in scenario order, of the
  # verified commit, without a withdrawn name.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @verify "st_m1mqbeywdg"

  @commit String.duplicate("c", 40)
  @older String.duplicate("d", 40)

  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  @ac1 ~s|AC-1, "After a reload, the total still includes the voucher"|
  @ac2 ~s|AC-2, "On a phone, the voucher line fits the payment step"|
  @ac3 ~s|AC-3, "An expired voucher leaves the total unchanged"|
  @check "Check that the voucher line fits in the pictures of scenario 2, because the run could not measure the line on a phone screen."

  @verification """
  ## Summary

  Commit: #{@commit}. Two criteria are met.

  ## Matrix

  | Criterion | State | Evidence |
  |---|---|---|
  | #{@ac1} | Met | Film: demo-video scenario-1 v1, step 2 passed. |
  | #{@ac2} | Needs a person | #{@check} |
  | #{@ac3} | Not met | Locked check `tests/voucher.test.ts` failed: 2 of 3 tests passed. |

  ## Lowered

  - None.

  ## Not verified

  - #{@ac2}: #{@check}

  ## Accepted findings

  - None.

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

  # A work item at Verify's gate, whose run of Verify pushed what `push` pushes, with the
  # run of the queue and the work item, then passed.
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

  defp steps(titles),
    do:
      for(
        {title, i} <- Enum.with_index(titles, 1),
        do: %{"step" => i, "title" => title, "expected" => "Result #{i} of #{title}."}
      )

  # A scenario's film or pictures, and its demo evidence of `commit`.
  defp scenario!(run, work_item, n, kind, commit \\ @commit) do
    name = "scenario-#{n}"
    titles = ["Open #{name}", "Reload #{name}"]

    {type, files} =
      case kind do
        :film ->
          {"demo-video",
           [
             {"#{name}.mp4", @mp4},
             {"#{name}.vtt", "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOpen\n"}
           ]}

        :pictures ->
          {"screenshot", [{"#{name}-step-2.png", @png}, {"#{name}-step-1.png", @png}]}
      end

    media = push!(run, work_item, type, name, files)

    evidence = %{
      "scenario" => name,
      "title" => "Title of #{name}",
      "commit" => commit,
      "planned" => if(kind == :film, do: "film", else: "pictures"),
      "evidence" => if(kind == :film, do: "film", else: "pictures"),
      "verdict" => "passed",
      "script" => %{"type" => "demo-script", "name" => name, "version" => 1},
      "media" => %{"type" => type, "name" => name, "version" => media.number},
      "steps" => steps(titles)
    }

    push!(run, work_item, "demo-evidence", name, [{"#{name}.json", Jason.encode!(evidence)}])
    media
  end

  defp verification!(run, work_item, text \\ @verification),
    do: push!(run, work_item, "verification", "main", [{"verification.md", text}])

  defp tab(conn, scope, work_item) do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/stages/#{@verify}"
      )

    view
  end

  # The tab of Explore, the stage of the proposal.
  defp item_page(conn, scope, work_item) do
    {:ok, view, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/explore")

    view
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "the verification" do
    test "the matrix, the not verified list and the model families", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)
      view = tab(conn, scope, work_item)
      parts = "#work-item-tab-output-verification-parts"

      assert has_element?(view, "#work-item-tab-output-verification-h", "Verification")

      assert has_element?(
               view,
               "#work-item-tab-output-verification-s",
               "Version 1 · Model families: Build claude · Verify deepseek"
             )

      assert texts(view, "#{parts}-matrix tr td:first-child") == [
               "#{@ac1} Film: demo-video scenario-1 v1, step 2 passed.",
               "#{@ac2} #{@check}",
               "#{@ac3} Locked check tests/voucher.test.ts failed: 2 of 3 tests passed."
             ]

      assert texts(view, "#{parts}-matrix tr td:nth-child(2)") ==
               ["Met", "Needs a person", "Not met"]

      assert has_element?(view, "#{parts}-matrix-1 td.q-from-sm", @check)
      assert has_element?(view, "#{parts}-matrix-0 .badge.bg-success-soft", "Met")
      assert has_element?(view, "#{parts}-matrix-1 .badge.bg-primary-soft", "Needs a person")
      assert has_element?(view, "#{parts}-matrix-2 .badge.bg-error-soft", "Not met")

      assert texts(view, "#{parts}-not-verified li span") == [@ac2, @check]

      assert has_element?(
               view,
               "#{parts} #work-item-tab-output-verification-row",
               "verification v1"
             )

      refute has_element?(view, "#{parts}-accepted")
    end

    test "after a member accepted the escalation: who, above the matrix; the row stays",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)

      Repo.insert!(%Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        stage_id: @verify,
        process_version_id: work_item.process_version_id,
        round: 1,
        cause: :run_stopped,
        resolution: :accept,
        resolved_by_id: scope.user.id,
        resolved_at: DateTime.add(DateTime.utc_now(), 1, :second),
        inserted_at: DateTime.utc_now()
      })

      view = tab(conn, scope, work_item)
      name = ApiaryWeb.People.short(scope.user.email)

      assert texts(view, "#work-item-tab-output-verification-parts > *") |> hd() ==
               "Accepted as it is by #{name}"

      assert has_element?(
               view,
               "#work-item-tab-output-verification-parts-matrix-2 .badge",
               "Not met"
             )

      refute has_element?(view, "#work-item-stage-gate", "Accepted as it is")
    end

    test "an escalation accepted before the verification shows no member",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)

      Repo.insert!(%Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        stage_id: @verify,
        process_version_id: work_item.process_version_id,
        round: 1,
        cause: :run_stopped,
        resolution: :accept,
        resolved_by_id: scope.user.id,
        resolved_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        inserted_at: DateTime.add(DateTime.utc_now(), -3700, :second)
      })

      view = tab(conn, scope, work_item)
      assert has_element?(view, "#work-item-tab-output-verification-parts-matrix")
      refute has_element?(view, "#work-item-tab-output-verification-parts-accepted")
    end

    test "a verification with no matrix is shown as its Markdown", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, &verification!(&1, &2, "## Summary\n\nThe check passed.\n"))

      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-output-verification", "The check passed.")
      refute has_element?(view, "#work-item-tab-output-verification-parts")
    end
  end

  describe "the scenarios" do
    test "one frame, in scenario order, each film with its steps and each picture with its step",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 10, :film)
          scenario!(run, work_item, 2, :pictures)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-output-demo-video-h", "Scenarios")
      assert has_element?(view, "#work-item-tab-output-demo-video-s", "Version 1 · 3 scenarios")
      refute has_element?(view, "#work-item-tab-output-screenshot")

      assert texts(view, "#work-item-tab-scenarios h3") == [
               "Scenario 1: Title of scenario-1",
               "Scenario 2: Title of scenario-2",
               "Scenario 10: Title of scenario-10"
             ]

      film = "#work-item-tab-scenarios-demo-video-scenario-1"
      assert has_element?(view, "#{film} video source[type=\"video/mp4\"]")

      assert has_element?(
               view,
               "#{film} video track[kind=\"captions\"][label=\"scenario-1.vtt\"]"
             )

      assert has_element?(view, "#{film} figcaption", "scenario-1.mp4")

      assert texts(view, "#{film}-steps li") == [
               "Step 1: Open scenario-1 Expected: Result 1 of Open scenario-1.",
               "Step 2: Reload scenario-1 Expected: Result 2 of Reload scenario-1."
             ]

      assert has_element?(view, "#{film}-row", "demo-video scenario-1 v1")

      pictures = "#work-item-tab-scenarios-screenshot-scenario-2"

      assert has_element?(
               view,
               pictures,
               "Pictures, one for each step, 390 px wide."
             )

      assert texts(view, "#{pictures}-pictures figcaption") == [
               "Step 1: Open scenario-2 Expected: Result 1 of Open scenario-2.",
               "Step 2: Reload scenario-2 Expected: Result 2 of Reload scenario-2."
             ]

      assert [first, second] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#{pictures}-pictures img")
               |> Enum.map(&(&1 |> LazyHTML.attribute("src") |> hd()))

      assert first =~ "scenario-2-step-1.png"
      assert second =~ "scenario-2-step-2.png"
      assert has_element?(view, "#{pictures}-row", "screenshot scenario-2 v1")

      # The demo evidence, once its frame opens, has one row per name, in name order.
      view |> element("#work-item-tab-output-demo-evidence-s") |> render_click()

      assert texts(view, "#work-item-tab-output-demo-evidence-row li > div") == [
               "demo-evidence scenario-1 v1",
               "demo-evidence scenario-2 v1",
               "demo-evidence scenario-10 v1"
             ]
    end

    test "only the scenarios of the verified commit", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film, @older)
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
    end

    test "a withdrawn scenario is not on the tab and not in the approval",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
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

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
      refute has_element?(view, "#work-item-stage-gate-output-demo-video-scenario-2")
      assert has_element?(view, "#work-item-stage-gate-output-demo-video-scenario-1")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      approvals =
        for %{type: "demo-video", name: name, versions: versions} <-
              Stages.artifact_index(work_item),
            into: %{},
            do: {name, Enum.flat_map(versions, & &1.approvals)}

      assert [_approval] = approvals["scenario-1"]
      assert approvals["scenario-2"] == []
    end

    test "a stage with no demo evidence: each film with its demo script's steps",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          push!(run, work_item, "demo-video", "scenario-3", [{"scenario-3.mp4", @mp4}])

          script = %{
            "scenario" => "scenario-3",
            "title" => "Title of scenario-3",
            "steps" => steps(["Open the cart"])
          }

          push!(run, work_item, "demo-script", "scenario-3", [
            {"scenario-3.json", Jason.encode!(script)}
          ])
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 3: Title of scenario-3"]

      assert texts(view, "#work-item-tab-scenarios-demo-video-scenario-3-steps li") == [
               "Step 1: Open the cart Expected: Result 1 of Open the cart."
             ]
    end

    test "with no scenario of the verified commit, no Scenarios frame", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film, @older)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-output-verification")
      refute has_element?(view, "#work-item-tab-output-demo-video")
    end
  end

  describe "a version a cancelled run wrote" do
    test "after an approval, it shows no newer version", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)
      newest = newest_run(work_item)

      run =
        %DispatchRun{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id
        }
        |> DispatchRun.queue_changeset(%{
          work_item_id: work_item.id,
          step: newest.step,
          take_in: newest.take_in,
          attempt: newest.attempt + 1,
          of: max(newest.of, newest.attempt + 1),
          queued_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, %{number: 2}} =
        Stages.Artifacts.push(
          {:run, run},
          work_item,
          "proposal",
          [
            %{
              filename: "proposal.md",
              content_type: "text/markdown",
              binary: understood_result()["message"]
            }
          ],
          stage_id: @explore
        )

      view = item_page(conn, scope, work_item)
      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      Apiary.RunEventsFixtures.run_fixture(scope, %{
        dispatch_run_id: run.id,
        cancel_requested_at: DateTime.utc_now()
      })

      view = item_page(conn, scope, work_item)
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")
      refute has_element?(view, "#work-item-marks-proposal-main-m")
      refute has_element?(view, "#work-item-marks", "Changed after approval")
    end
  end
end

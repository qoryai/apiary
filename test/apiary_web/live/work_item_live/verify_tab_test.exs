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

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.ArtifactLive.Markdown
  alias ApiaryWeb.WorkItemLive.{StageTab, VerifyTab}
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

  # A run of the queue at Verify for `work_item`, of the take in `take_in`, after its
  # newest run.
  defp verify_run!(work_item, take_in) do
    newest = newest_run(work_item)

    %DispatchRun{organisation_id: work_item.organisation_id, workspace_id: work_item.workspace_id}
    |> DispatchRun.queue_changeset(%{
      work_item_id: work_item.id,
      step: newest.step,
      take_in: take_in,
      attempt: newest.attempt + 1,
      of: max(newest.of, newest.attempt + 1),
      queued_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.put_change(:stage_id, @verify)
    |> Repo.insert!()
  end

  # The run, cancelled by a member.
  defp cancel!(scope, run) do
    Apiary.RunEventsFixtures.run_fixture(scope, %{
      dispatch_run_id: run.id,
      cancel_requested_at: DateTime.utc_now()
    })
  end

  defp explainer!(run, work_item) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        "explainer",
        [
          %{
            filename: "explainer.md",
            content_type: "text/markdown",
            binary: "Words of the explainer."
          }
        ],
        stage_id: run.stage_id
      )

    version
  end

  # A matrix of `rows`, each `{criterion, state, evidence}`, with the commit `@commit`.
  defp matrix(rows) do
    """
    ## Summary

    Commit: #{@commit}.

    ## Matrix

    | Criterion | State | Evidence |
    |---|---|---|
    #{Enum.map_join(rows, "\n", fn {criterion, state, evidence} -> "| #{criterion} | #{state} | #{evidence} |" end)}

    ## Model families

    Build: claude.
    """
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

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

      film = "#work-item-tab-scenarios-scenario-1"
      assert has_element?(view, "#{film} video source[type=\"video/mp4\"]")

      assert has_element?(
               view,
               "#{film} video track[kind=\"captions\"][label=\"scenario-1.vtt\"]"
             )

      assert has_element?(view, "#{film} figcaption", "scenario-1.mp4")

      # The captions start off: no track is the default one.
      refute has_element?(view, "#{film} video track[default]")
      refute has_element?(view, "#work-item-tab-scenarios video track[default]")

      assert texts(view, "#{film}-steps li") == [
               "Step 1: Open scenario-1 Expected: Result 1 of Open scenario-1.",
               "Step 2: Reload scenario-1 Expected: Result 2 of Reload scenario-1."
             ]

      assert has_element?(view, "#{film}-row", "demo video scenario-1 v1")

      pictures = "#work-item-tab-scenarios-scenario-2"

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

      # The demo evidence has one row per name, in name order.
      assert texts(view, "#work-item-tab-output-demo-evidence-row li > div") == [
               "demo evidence scenario-1 v1",
               "demo evidence scenario-2 v1",
               "demo evidence scenario-10 v1"
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
      refute has_element?(view, "#work-item-stage-gate-output-demo-video--scenario-2--")
      assert has_element?(view, "#work-item-stage-gate-output-demo-video--scenario-1--")

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

  describe "verification/1" do
    test "a text over the byte limit or not UTF-8 has no parts" do
      assert %{commit: @commit} = VerifyTab.verification(@verification)
      assert VerifyTab.verification(String.duplicate("a", Markdown.max_bytes() + 1)) == nil
      assert VerifyTab.verification(@verification <> <<0xFF, 0xFE>>) == nil
    end

    test "a text whose tables could pass the cell bound is refused before it is parsed" do
      # 1,001 cells a line on 101 lines: past the bound, in under 4 KB.
      text =
        @verification <> "\n|" <> String.duplicate("|", 1_000) <> String.duplicate("\n|", 100)

      assert byte_size(text) < Markdown.max_bytes()
      refute Markdown.formattable?(text)
      assert VerifyTab.verification(text) == nil
    end

    test "a header with a fourth column is no matrix" do
      text = """
      ## Matrix

      | Criterion | State | Evidence | Notes |
      |---|---|---|---|
      | #{@ac1} | Met | Tests passed. | None. |
      """

      assert VerifyTab.verification(text) == nil
    end

    test "a row with too few cells has empty ones; a row with too many keeps three" do
      text = """
      ## Matrix

      | Criterion | State | Evidence |
      |---|---|---|
      | #{@ac1} | Met |
      | #{@ac2} | Not met | The test failed. | An extra cell. |
      """

      assert %{rows: rows, commit: nil} = VerifyTab.verification(text)

      assert rows == [
               %{criterion: @ac1, state: :met, evidence: ""},
               %{criterion: @ac2, state: :not_met, evidence: "The test failed."}
             ]
    end

    test "raw HTML in a cell is kept as its text" do
      text = matrix([{@ac1, "Met", "<script>alert(1)</script> <img src=x onerror=alert(2)>"}])

      assert %{rows: [%{evidence: evidence}]} = VerifyTab.verification(text)
      assert evidence == "<script>alert(1)</script> <img src=x onerror=alert(2)>"
    end

    test "a model's name with a dot stays whole" do
      text = matrix([]) <> "\nVerify: gpt-5.1.\n"
      assert %{families: ["Build claude", "Verify gpt-5.1"]} = VerifyTab.verification(text)

      text =
        String.replace(
          @verification,
          "Build: claude. Verify: deepseek.",
          "Build: claude-4.5. Verify: gpt-5.1."
        )

      assert %{families: ["Build claude-4.5", "Verify gpt-5.1"]} = VerifyTab.verification(text)
    end
  end

  describe "the tab's frames" do
    test "every frame is open; the demo evidence and the explainer have their row only",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          explainer!(run, work_item)
        end)

      view = tab(conn, scope, work_item)

      for type <- ["verification", "demo-video", "demo-evidence", "explainer"] do
        assert has_element?(view, "#work-item-tab-output-#{type}-fold[open]")
      end

      explainer = "#work-item-tab-output-explainer"
      assert has_element?(view, "#{explainer}-s", "Version 1")
      assert has_element?(view, "#{explainer}-row", "explainer v1")
      refute has_element?(view, explainer, "Words of the explainer.")
      refute has_element?(view, "#{explainer}-text")
      assert has_element?(view, "#work-item-tab-output-demo-evidence-s", "Version 1")
    end

    test "the rows and the tab's Artifacts list show the plain label",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(
               view,
               "#work-item-tab-scenarios-scenario-1-row",
               "demo video scenario-1 v1"
             )

      assert has_element?(
               view,
               "#work-item-tab-output-demo-evidence-row",
               "demo evidence scenario-1 v1"
             )

      # The tab's Artifacts list has the same words; the page's other lists and the
      # artifact page keep the type's id.
      assert has_element?(view, "#work-item-artifact-list", "demo video scenario-1 v1")
      refute has_element?(view, "#work-item-artifact-list", "demo-video scenario-1 v1")

      explore = item_page(conn, scope, work_item)
      refute has_element?(explore, "#work-item-artifact-list", "demo video scenario-1 v1")
    end

    test "a scenario has no bottom padding, as the signed-off picture draws it",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      view = tab(conn, scope, work_item)

      for id <- ["scenario-1", "scenario-2"] do
        [class] =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query("#work-item-tab-scenarios-#{id}")
          |> LazyHTML.attribute("class")

        assert class =~ "border-b"
        refute class =~ "pb-"
      end
    end

    test "the gate card lists the films and pictures together, in scenario order",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 10, :film)
          scenario!(run, work_item, 2, :pictures)
          scenario!(run, work_item, 1, :film)
          explainer!(run, work_item)
        end)

      view = tab(conn, scope, work_item)

      assert ids(view, "#work-item-stage-gate-outputs li") ==
               Enum.map(
                 ~w(verification demo-video--scenario-1-- screenshot--scenario-2--
                    demo-video--scenario-10-- demo-evidence--scenario-1--
                    demo-evidence--scenario-2-- demo-evidence--scenario-10-- explainer),
                 &"work-item-stage-gate-output-#{&1}"
               )

      assert has_element?(
               view,
               "#work-item-stage-gate-output-screenshot--scenario-2--",
               "screenshot scenario-2 v1"
             )
    end
  end

  describe "the matrix's evidence" do
    test "links each scenario of the Scenarios frame; other text stays text, escaped",
         %{conn: conn, scope: scope} do
      check =
        "Check that the voucher line fits in the pictures of scenario 2, because the run could not measure the line."

      text =
        matrix([
          {@ac1, "Met", "Demo video: scenario 1"},
          {@ac2, "Needs a person", check},
          {@ac3, "Met", "Pictures: scenario 7"},
          {~s|AC-4, "Raw HTML stays text"|, "Met",
           "<script>alert(1)</script> <img src=x onerror=alert(2)>"}
        ])

      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item, text)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      view = tab(conn, scope, work_item)
      matrix = "#work-item-tab-output-verification-parts-matrix"

      for cell <- ["td.q-from-sm", "td:first-child div"] do
        assert has_element?(
                 view,
                 ~s|#{matrix}-0 #{cell} a[href="#work-item-tab-scenarios-scenario-1"]|,
                 "Demo video: scenario 1"
               )

        assert has_element?(
                 view,
                 ~s|#{matrix}-1 #{cell} a[href="#work-item-tab-scenarios-scenario-2"]|,
                 "the pictures of scenario 2"
               )
      end

      assert texts(view, "#{matrix}-1 td.q-from-sm") == [check]
      assert has_element?(view, "#work-item-tab-scenarios-scenario-1")
      assert has_element?(view, "#work-item-tab-scenarios-scenario-2")

      assert has_element?(view, "#{matrix}-2 td.q-from-sm", "Pictures: scenario 7")
      refute has_element?(view, "#{matrix}-2 a")

      assert has_element?(view, "#{matrix}-3 td.q-from-sm", "<script>alert(1)</script>")
      refute has_element?(view, "#{matrix} script")
      refute has_element?(view, "#{matrix} img")
    end

    test "evidence_parts/2 links the three phrases whole, and no other text" do
      anchors = %{1 => "a-1", 2 => "a-2"}

      assert VerifyTab.evidence_parts("Demo video: scenario 1", anchors) ==
               [{:link, "Demo video: scenario 1", "a-1"}]

      assert VerifyTab.evidence_parts("Pictures: scenario 2", anchors) ==
               [{:link, "Pictures: scenario 2", "a-2"}]

      assert VerifyTab.evidence_parts(
               "Check that the voucher line fits in the pictures of scenario 2, because the run could not.",
               anchors
             ) ==
               [
                 "Check that the voucher line fits in ",
                 {:link, "the pictures of scenario 2", "a-2"},
                 ", because the run could not."
               ]

      # Another number, another wording and a scenario not listed stay text.
      for text <- [
            "Film: demo-video scenario-1 v1, scenario-12 too.",
            "scenario 2 passed",
            "Demo video: scenario 7",
            "Pictures: scenario 12"
          ] do
        assert VerifyTab.evidence_parts(text, anchors) == [text]
      end

      assert VerifyTab.evidence_parts("Pictures: scenario 2", %{}) == ["Pictures: scenario 2"]
    end

    test "evidence_parts/2 matches the phrases case-sensitively and reads the number as an integer" do
      anchors = %{1 => "a-1", 2 => "a-2"}

      for text <- [
            "demo video: scenario 1",
            "The pictures of scenario 2",
            "pictures: scenario 2"
          ] do
        assert VerifyTab.evidence_parts(text, anchors) == [text]
      end

      assert VerifyTab.evidence_parts("Pictures: scenario 02", anchors) ==
               [{:link, "Pictures: scenario 02", "a-2"}]
    end
  end

  describe "the scenarios read" do
    test "with no Commit line, the evidence of every commit shows", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item, String.replace(@verification, "Commit: #{@commit}. ", ""))
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film, @older)
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == [
               "Scenario 1: Title of scenario-1",
               "Scenario 2: Title of scenario-2"
             ]
    end

    test "a cancelled run's verification does not change the verified commit",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      run = verify_run!(work_item, work_item.take_in)
      verification!(run, work_item, String.replace(@verification, @commit, @older))
      cancel!(scope, run)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
    end

    test "a scenario's row shows the film its evidence names, not a newer one",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          push!(run, work_item, "demo-video", "scenario-1", [{"scenario-1.mp4", @mp4 <> "2"}])
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(
               view,
               "#work-item-tab-scenarios-scenario-1-row",
               "demo video scenario-1 v1"
             )

      refute has_element?(view, "#work-item-tab-scenarios-scenario-1-row", "v2")
    end

    test "two scenarios with one film have one element each", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          film = scenario!(run, work_item, 1, :film)

          evidence = %{
            "scenario" => "scenario-3",
            "title" => "Title of scenario-3",
            "commit" => @commit,
            "media" => %{"type" => "demo-video", "name" => "scenario-1", "version" => film.number},
            "steps" => steps(["Open the cart"])
          }

          push!(run, work_item, "demo-evidence", "scenario-3", [
            {"scenario-3.json", Jason.encode!(evidence)}
          ])
        end)

      view = tab(conn, scope, work_item)

      assert ids(view, "#work-item-tab-scenarios > div") == [
               "work-item-tab-scenarios-scenario-1",
               "work-item-tab-scenarios-scenario-3"
             ]
    end

    test "an earlier take in's names and films stay off the tab", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film)
        end)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [take_in: work_item.take_in + 1]
        )

      work_item = Repo.get!(WorkItem, work_item.id)
      run = verify_run!(work_item, work_item.take_in)
      verification!(run, work_item)
      scenario!(run, work_item, 1, :film)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
      refute has_element?(view, "#work-item-tab-scenarios-scenario-2")

      assert texts(view, "#work-item-tab-output-demo-evidence-row li > div") == [
               "demo evidence scenario-1 v2"
             ]
    end

    test "each JSON document and the accepting member are read once",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)
      assigns = :sys.get_state(view.pid).socket.assigns

      [evidence] =
        for %{type: "demo-evidence"} = artifact <- assigns.artifacts,
            do: hd(artifact.versions)

      assert %{"title" => "Title of scenario-1"} =
               assigns.stored_reads[{:json, evidence.public_id}]

      [accepted] = for {:accepted, _, _, _} = key <- Map.keys(assigns.stored_reads), do: key

      # What the page keeps is what it shows again, when the frames are read again.
      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, fn assigns ->
          %{
            assigns
            | frame_texts: %{},
              stored_reads:
                assigns.stored_reads
                |> Map.update!({:json, evidence.public_id}, &Map.put(&1, "title", "Kept"))
                |> Map.put(accepted, "kept-member")
          }
        end)
      end)

      send(view.pid, {:artifact_pushed, work_item.id, evidence.public_id})

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Kept"]

      assert has_element?(
               view,
               "#work-item-tab-output-verification-parts-accepted",
               "Accepted as it is by kept-member"
             )
    end
  end

  describe "a verification shown as its Markdown" do
    test "after a member accepted the escalation: who, above the text",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, &verification!(&1, &2, "## Summary\n\nThe check passed.\n"))

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

      assert has_element?(
               view,
               "#work-item-tab-output-verification-accepted",
               "Accepted as it is by #{name}"
             )

      assert has_element?(view, "#work-item-tab-output-verification", "The check passed.")
    end
  end

  describe "a person's versions on the tab (780 (c))" do
    # A version that the scope's member adds at the work item's stage.
    defp upload!(scope, work_item, type, name, files) do
      {:ok, version} =
        Stages.add_version(scope, Repo.get!(WorkItem, work_item.id), type, files, name: name)

      version
    end

    defp picture(name),
      do: [%{filename: "#{name}-step-1.png", content_type: "image/png", binary: @png}]

    defp words(text),
      do: [%{filename: "explainer.md", content_type: "text/markdown", binary: text}]

    # The versions that the newest approval of Verify records.
    defp recorded(work_item) do
      Repo.one(
        from d in Apiary.Stages.GateDecision,
          where:
            d.work_item_id == ^work_item.id and d.kind == :approve and d.stage_id == ^@verify,
          order_by: [desc: d.inserted_at],
          limit: 1,
          select: d.versions
      )
    end

    test "a picture is a Scenarios entry with its caption, and the count has it",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      phone = upload!(scope, work_item, "screenshot", "phone-check", picture("phone-check"))
      view = tab(conn, scope, work_item)
      short = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(view, "#work-item-tab-output-demo-video-s", "Version 1 · 3 scenarios")

      assert texts(view, "#work-item-tab-scenarios h3") == [
               "Scenario 1: Title of scenario-1",
               "Scenario 2: Title of scenario-2",
               "phone-check"
             ]

      entry = "#work-item-tab-scenarios-screenshot--phone-check--"
      assert has_element?(view, "#{entry}-caption", "Version 1 · #{short}")
      assert has_element?(view, "#{entry}-pictures img")
      assert has_element?(view, "#{entry}-row", "screenshot phone-check v1")
      refute has_element?(view, "#work-item-tab-scenarios-scenario-2-caption")
      refute has_element?(view, "#work-item-tab-output-screenshot")

      # The gate card lists the picture once, on its row.
      assert has_element?(
               view,
               "#work-item-stage-gate-output-screenshot--phone-check--",
               "screenshot phone-check v1"
             )

      refute has_element?(view, "#work-item-stage-gate-recorded")

      {:ok, _approved} =
        Stages.approve(scope, Repo.get!(WorkItem, work_item.id), nil, expect_stage: @verify)

      assert phone.public_id in recorded(work_item)
    end

    test "a version of another type is a row, and its frame has the caption",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          explainer!(run, work_item)
        end)

      upload!(scope, work_item, "explainer", "main", words("Words by hand."))
      upload!(scope, work_item, "demo-evidence", "extra", words("Evidence by hand."))
      view = tab(conn, scope, work_item)
      short = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(view, "#work-item-tab-output-explainer-s", "Version 2 · #{short}")
      assert has_element?(view, "#work-item-tab-output-explainer-row", "explainer v2")
      refute has_element?(view, "#work-item-tab-output-explainer-v2")

      # A type that no run wrote has a row frame from the person's version alone.
      assert has_element?(view, "#work-item-tab-output-demo-evidence-s", "Version 1 · #{short}")

      assert has_element?(
               view,
               "#work-item-tab-output-demo-evidence-row",
               "demo evidence extra v1"
             )
    end

    test "a row frame whose highest version a run wrote has no member in its caption",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          explainer!(run, work_item)
        end)

      upload!(scope, work_item, "explainer", "notes", words("Notes by hand."))
      view = tab(conn, scope, work_item)
      short = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(view, "#work-item-tab-output-explainer-s", "Version 1")
      refute has_element?(view, "#work-item-tab-output-explainer-s", short)
      assert has_element?(view, "#work-item-tab-output-explainer-row", "explainer v1")
      assert has_element?(view, "#work-item-tab-output-explainer-row", "explainer notes v1")
    end

    test "with no run's film or picture, a person's picture has the Scenarios frame",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!(&1, &2))
      upload!(scope, work_item, "screenshot", "phone-check", picture("phone-check"))
      view = tab(conn, scope, work_item)
      short = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(view, "#work-item-tab-output-screenshot-h", "Scenarios")
      assert has_element?(view, "#work-item-tab-output-screenshot-s", "Version 1 · 1 scenario")
      assert texts(view, "#work-item-tab-scenarios h3") == ["phone-check"]

      assert has_element?(
               view,
               "#work-item-tab-scenarios-screenshot--phone-check---caption",
               "Version 1 · #{short}"
             )
    end

    test "a person's change of a type that is not Verify's output is a row frame after them",
         %{conn: conn, scope: scope} do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => "notes", "base_view" => "file"})

      work_item = at_verify_gate!(scope, &verification!(&1, &2))
      upload!(scope, work_item, "notes", "main", words("Notes by hand."))
      view = tab(conn, scope, work_item)
      short = ApiaryWeb.People.short(scope.user.email)

      assert ids(view, "section.q-xp-frame") == [
               "work-item-tab-output-verification",
               "work-item-tab-output-notes"
             ]

      assert has_element?(view, "#work-item-tab-output-notes-s", "Version 1 · #{short}")
      assert has_element?(view, "#work-item-tab-output-notes-row", "notes v1")
    end

    test "a person's picture alone has the Scenarios frame, open, then the inputs, folded" do
      stage = %{outputs: ~w(verification demo-video screenshot explainer)}
      version = %{public_id: "av_phone", number: 1, writer: :person, user: nil}
      phone = %{type: "screenshot", name: "phone-check", version: version}

      assert [frame] = StageTab.verify_frames(stage, %{}, [phone])

      assert %{
               type: "screenshot",
               kind: :scenarios,
               version: 1,
               open: true,
               persons: [%{name: "phone-check", id: "av_phone"}]
             } = frame

      input = &%{type: &1, name: "main", version: 2, open: &2, writer: nil, kind: :output}
      inputs = [input.("build-report", true), input.("screenshot", false), input.("spec", false)]

      assert [^frame, %{type: "build-report", open: false}, %{type: "spec", open: false}] =
               StageTab.with_inputs([frame], inputs)
    end
  end
end

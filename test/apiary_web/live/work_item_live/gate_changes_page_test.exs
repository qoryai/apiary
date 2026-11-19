defmodule ApiaryWeb.WorkItemLive.GateChangesPageTest do
  # The gate after a person's Request changes: Build's second run stores a new
  # version of the acceptance criteria with that request as its `decision`, and the work
  # item page marks the version, on the gate card and on its frame on Build's tab, and
  # lists each changed, added or removed criterion with its earlier and new text, until a
  # person's approval lists the version. Every state comes from real runs and a real
  # Request changes. Three people: the person who asked, another approver of Build, and a
  # member Build does not list.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures, only: [understood_result: 0]

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.OrganisationsFixtures, as: OF
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"

  @workflows ~w(shape-a-ticket plan-the-build verify-a-ticket)

  @note "Change the acceptance criteria: let members cancel up to 12 hours before the start, not 24."

  @ac1 %{
    "id" => "ac-1",
    "text" => "A member cancels a booking of theirs on My bookings with Cancel booking.",
    "check" =>
      "Sign in as a member with a booking, pick Cancel booking on My bookings: the booking leaves the list."
  }

  @ac3 %{
    "id" => "ac-3",
    "text" => "The member gets an email that confirms the cancellation.",
    "check" => "Cancel a booking: the member's inbox has the email within a minute."
  }

  @criteria_one %{
    "summary" => "Members cancel their bookings on the booking site.",
    "criteria" => [
      @ac1,
      %{
        "id" => "ac-2",
        "text" => "A member can cancel up to 24 hours before the booking starts.",
        "check" =>
          "Cancel a booking that starts in 25 hours and one that starts in 23 hours: the first is cancelled, the second shows why not."
      },
      @ac3
    ]
  }

  @criteria_two %{
    "summary" => "Members cancel their bookings on the booking site.",
    "criteria" => [
      @ac1,
      %{
        "id" => "ac-2",
        "text" => "A member can cancel up to 12 hours before the booking starts.",
        "check" =>
          "Book a court for 11 hours from now, then pick Cancel booking: the page shows \"You can cancel up to 12 hours before the start.\" and keeps the booking."
      },
      Map.put(@ac3, "removed", %{"reason" => "The club sends no emails yet."}),
      %{
        "id" => "ac-4",
        "text" => "The court shows as free on the booking page right after the cancellation.",
        "check" => "Cancel a booking, then open the booking page: the court is free at that time."
      }
    ]
  }

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup do
    n = System.unique_integer([:positive])
    %{user: sam} = OF.sign_up_fixture(%{email: "sam#{n}@example.com"})
    scope = Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(sam))
    workspace = scope.workspace

    [alex, kim] =
      for name <- ~w(alex kim) do
        %{token: token} = OF.invitation_fixture(scope, %{"email" => "#{name}#{n}@example.com"})

        %{user: user} =
          OF.sign_up_fixture(%{email: "#{name}#{n}@example.com", invitation_token: token})

        user
      end

    :ok =
      Processes.record_declared(
        workspace,
        Processes.qory_workflows(Apiary.Stacks.Sources.chosen(workspace)) ++ @workflows
      )

    for workflow <- @workflows do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        workflow: workflow,
        access: :read
      })
    end

    for name <- ~w(spec build-report) do
      {:ok, _type} =
        Artifacts.create_type(scope, workspace, %{
          "name" => name,
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })
    end

    process!(scope, [sam.id, alex.id])

    %{
      scope: scope,
      sam: sam,
      alex: alex,
      kim: kim,
      names: %{sam: "sam#{n}", alex: "alex#{n}"},
      alex_scope: OF.workspace_scope(alex, workspace)
    }
  end

  # The default process with Shape writing the spec and the acceptance criteria, Build
  # reading them and writing a build report, its gate listing `approvers`, and Verify.
  defp process!(scope, approvers) do
    document = Processes.default_document("software")

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage ->
          Map.merge(stage, %{
            "sequence" => [%{"workflow" => "shape-a-ticket"}],
            "outputs" => [
              %{"type" => "spec", "required" => false},
              %{"type" => "acceptance-criteria", "required" => false}
            ],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })

        %{"id" => @build} = stage ->
          Map.merge(stage, %{
            "inputs" => [
              %{"type" => "spec", "required" => false},
              %{"type" => "acceptance-criteria", "required" => false}
            ],
            "sequence" => [%{"workflow" => "plan-the-build"}],
            "outputs" => [%{"type" => "build-report", "required" => false}],
            "gate" => %{"kind" => "person", "approvers" => %{"members" => approvers}}
          })

        %{"id" => @verify} = stage ->
          Map.merge(stage, %{
            "inputs" => [
              %{"type" => "acceptance-criteria", "required" => false},
              %{"type" => "build-report", "required" => false}
            ],
            "sequence" => [%{"workflow" => "verify-a-ticket"}],
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })

        stage ->
          stage
      end)

    {:ok, _version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
  end

  defp reload(%WorkItem{id: id}), do: Repo.get!(WorkItem, id)

  defp page(scope, number, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> rest

  defp end_run(work_item, fun), do: work_item |> reload() |> end_run!(fun) |> reload()

  defp markdown!(run, type, text) do
    {:ok, _version} =
      Artifacts.push(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        type,
        [%{filename: "#{type}.md", content_type: "text/markdown", binary: text}],
        stage_id: run.stage_id
      )
  end

  defp json!(run, type, document, opts \\ []) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        type,
        document,
        Keyword.put(opts, :stage_id, run.stage_id)
      )
  end

  defp passed!(run), do: json!(run, "verdict", %{"verdict" => "passed"})

  # A work item at Build's gate with acceptance criteria v2, which Build's second run
  # stored after the person of `asker` picked Request changes at Build's gate, with that
  # request as its `decision`.
  defp changed!(scope, asker \\ nil) do
    work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
    {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)

    work_item =
      end_run(work_item, fn run, _registered ->
        markdown!(run, "spec", "## Spec\n\nLet members cancel a booking.")
        json!(run, "acceptance-criteria", @criteria_one)
        passed!(run)
      end)

    {:ok, _at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

    work_item =
      end_run(work_item, fn run, _registered ->
        markdown!(run, "build-report", "## Build report\n\nA cancel rule of 24 hours.")
        passed!(run)
      end)

    assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

    {:ok, _again} =
      Stages.request_changes(asker || scope, work_item, @note, nil, expect_stage: @build)

    decision =
      Repo.one!(
        from d in Stages.GateDecision,
          where: d.work_item_id == ^work_item.id and d.kind == :request_changes,
          select: d.public_id
      )

    work_item =
      end_run(work_item, fn run, _registered ->
        json!(run, "acceptance-criteria", @criteria_two, decision: decision)
        markdown!(run, "build-report", "## Build report\n\nA cancel rule of 12 hours.")
        passed!(run)
      end)

    assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item
    work_item
  end

  # The text of `selector` on the page, its white space as one space each.
  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  @card "#work-item-stage-gate"
  @list "#work-item-stage-gate-criteria"

  # The lines of `selector` on the page, one for each paragraph, as `text/2` has them.
  defp lines(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("p")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  # The criteria as the card lists them, line by line, the same for every reader but the
  # mark.
  defp criteria_lines(mark) do
    [
      {"#{@list}-ac-2",
       [
         "AC-2 · #{mark}",
         "Earlier: A member can cancel up to 24 hours before the booking starts.",
         "New: A member can cancel up to 12 hours before the booking starts.",
         "Earlier check: Cancel a booking that starts in 25 hours and one that starts in 23 hours: the first is cancelled, the second shows why not.",
         "New check: Book a court for 11 hours from now, then pick Cancel booking: the page shows \"You can cancel up to 12 hours before the start.\" and keeps the booking."
       ]},
      {"#{@list}-ac-3",
       [
         "AC-3 · #{mark}",
         "Earlier: The member gets an email that confirms the cancellation.",
         "New: Removed. Reason: The club sends no emails yet."
       ]},
      {"#{@list}-ac-4",
       [
         "AC-4 · #{mark}",
         "Earlier: none. This criterion is new.",
         "New: The court shows as free on the booking page right after the cancellation.",
         "New check: Cancel a booking, then open the booking page: the court is free at that time."
       ]}
    ]
  end

  defp assert_criteria(view, mark) do
    for {selector, expected} <- criteria_lines(mark),
        do: assert(lines(view, selector) == expected)

    assert text(view, "#{@list}-unchanged") == "AC-1 is unchanged."

    assert [_ac2, _ac3, _ac4] =
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#{@list}-list > li")
             |> Enum.to_list()

    # The changed lines in bold: the labels, not the texts.
    assert has_element?(view, "#{@list}-ac-2-earlier .font-semibold", "Earlier:")
    assert has_element?(view, "#{@list}-ac-2-new-check .font-semibold", "New check:")
    refute has_element?(view, "#{@list}-ac-3-new-check")
    refute has_element?(view, "#{@list}-ac-3-earlier-check")
    refute has_element?(view, "#{@list}-ac-4-earlier-check")
  end

  # The marks on the version's line of the card and on its frame's caption on Build's tab.
  defp assert_marks(view, mark) do
    assert text(view, "#{@card}-recorded-acceptance-criteria") ==
             "acceptance criteria v2 · #{mark}"

    assert has_element?(view, "#{@card}-recorded-acceptance-criteria-changed.text-warning", mark)
    # The build report, Build's output, has no decision: no mark.
    assert text(view, "#{@card}-output-build-report") == "build report v2 · Passed"

    assert text(view, "#work-item-tab-output-acceptance-criteria-s .q-xp-cap") ==
             "Version 2 · #{mark}"

    assert has_element?(
             view,
             "#work-item-tab-output-acceptance-criteria-changed.text-warning",
             mark
           )

    assert text(view, "#work-item-tab-output-build-report-s .q-xp-cap") == "Version 2"
  end

  test "the person who asked: the marks, the line of what to do, the criteria, both controls",
       %{conn: conn, scope: scope, sam: sam} do
    work_item = changed!(scope)
    conn = log_in_user(conn, sam)
    {:ok, view, _html} = live(conn, page(scope, work_item.number, "/stages/#{@build}"))

    mark = "Changed on your request"
    assert_marks(view, mark)

    assert text(view, "#{@list}-action") ==
             "Check that these 3 changes to the acceptance criteria match your request, then pick Approve or Request changes."

    assert has_element?(view, "#{@list}-action b", "Approve")
    assert has_element?(view, "#{@list}-action b", "Request changes")
    assert_criteria(view, mark)

    # For an approver the line about who may approve stays, and both controls show.
    assert text(view, "#{@card}-approvers") == "Only the members this stage lists can approve."
    assert has_element?(view, "#{@card}-approve-go", "Approve")
    assert has_element?(view, "#{@card}-ask-changes", "Request changes")
    refute has_element?(view, "#{@list}-approvers")

    # With the form of Request changes open, the line of what to do goes, as neither
    # control in it shows; the criteria stay.
    view |> element("#{@card}-ask-changes") |> render_click()
    assert has_element?(view, "#{@card}-changes")
    refute has_element?(view, "#{@card}-approve-go")
    refute has_element?(view, "#{@card}-ask-changes")
    refute has_element?(view, "#{@list}-action")
    assert_criteria(view, mark)
  end

  test "another approver: the person's name in every mark and in the line of what to do",
       %{conn: conn, scope: scope, alex: alex, names: names} do
    work_item = changed!(scope)
    conn = log_in_user(conn, alex)
    {:ok, view, _html} = live(conn, page(scope, work_item.number, "/stages/#{@build}"))

    mark = "Changed on #{names.sam}'s request"
    assert_marks(view, mark)

    assert text(view, "#{@list}-action") ==
             "Check that these 3 changes to the acceptance criteria match #{names.sam}'s request, then pick Approve or Request changes."

    assert_criteria(view, mark)
    assert text(view, "#{@card}-approvers") == "Only the members this stage lists can approve."
    assert has_element?(view, "#{@card}-approve-go", "Approve")
    assert has_element?(view, "#{@card}-ask-changes", "Request changes")
  end

  test "a member who may not approve: who decides, in place of what to do; no controls",
       %{conn: conn, scope: scope, kim: kim, names: names} do
    work_item = changed!(scope)
    conn = log_in_user(conn, kim)
    {:ok, view, _html} = live(conn, page(scope, work_item.number, "/stages/#{@build}"))

    mark = "Changed on #{names.sam}'s request"
    assert_marks(view, mark)

    assert text(view, "#{@list}-approvers") ==
             "An approver of Build decides: #{names.sam} and #{names.alex}."

    refute has_element?(view, "#{@list}-action")
    refute has_element?(view, "#{@card}-approvers")
    assert_criteria(view, mark)

    refute has_element?(view, "#{@card}-approve")
    refute has_element?(view, "#{@card}-ask-changes")
    refute has_element?(view, "#{@card}-changes")
  end

  test "a writer whose account is gone: a member's request",
       %{conn: conn, scope: scope, sam: sam, alex: alex, alex_scope: alex_scope} do
    work_item = changed!(scope, alex_scope)
    {:ok, _deleted} = Apiary.Accounts.delete_user(alex)

    conn = log_in_user(conn, sam)
    {:ok, view, _html} = live(conn, page(scope, work_item.number, "/stages/#{@build}"))

    mark = "Changed on a member's request"
    assert_marks(view, mark)

    assert text(view, "#{@list}-action") ==
             "Check that these 3 changes to the acceptance criteria match a member's request, then pick Approve or Request changes."

    assert_criteria(view, mark)
  end

  test "after a move back, the mark follows the output's check at the earlier gate",
       %{conn: conn, scope: scope, sam: sam} do
    work_item = changed!(scope)
    {:ok, moved} = Stages.move(scope, work_item, @shape, nil, expect_stage: @build)
    work_item = end_run(moved, fn run, _registered -> passed!(run) end)
    assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

    conn = log_in_user(conn, sam)
    {:ok, view, _html} = live(conn, page(scope, work_item.number, "/stages/#{@shape}"))

    mark = "Changed on your request"

    # Shape's approval listed v1, so today's approval marks follow the change's mark,
    # each part after " · " (`approval_mark/1`).
    assert text(view, "#{@card}-output-acceptance-criteria") ==
             "acceptance criteria v2 · Passed · #{mark} · " <>
               "Approved v1; v2 is newer · Changed after approval"

    assert has_element?(view, "#{@card}-output-acceptance-criteria-changed.text-warning", mark)
    refute has_element?(view, "#{@card}-recorded")

    assert text(view, "#{@list}-action") ==
             "Check that these 3 changes to the acceptance criteria match your request, then pick Approve or Request changes."

    assert_criteria(view, mark)
    assert has_element?(view, "#{@card}-approve-go", "Approve")
    assert has_element?(view, "#{@card}-ask-changes", "Request changes")
  end

  test "after a person's approval lists the version, no mark and no criteria",
       %{conn: conn, scope: scope, alex_scope: alex_scope, sam: sam} do
    work_item = changed!(scope)
    {:ok, _at_verify} = Stages.approve(alex_scope, reload(work_item), nil, expect_stage: @build)
    assert %WorkItem{stage_id: @verify} = reload(work_item)

    conn = log_in_user(conn, sam)
    {:ok, view, html} = live(conn, page(scope, work_item.number, "/stages/#{@build}"))

    assert text(view, "#work-item-tab-output-acceptance-criteria-s .q-xp-cap") == "Version 2"
    refute has_element?(view, "#work-item-tab-output-acceptance-criteria-changed")
    refute has_element?(view, @list)
    refute html =~ "Changed on"

    # Verify reads v2 at its gate, with no mark.
    work_item = end_run(work_item, fn run, _registered -> passed!(run) end)
    assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
    {:ok, view, html} = live(conn, page(scope, work_item.number))
    assert has_element?(view, "#{@card}-approve-go")
    refute html =~ "Changed on"
    refute has_element?(view, @list)
  end
end

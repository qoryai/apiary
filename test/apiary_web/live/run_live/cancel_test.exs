defmodule ApiaryWeb.RunLive.CancelTest do
  # Cancel run on a run's page (`ApiaryWeb.RunLive.Show`, `ApiaryWeb.RunCancelComponents`):
  # the button beside the state of a running run, or of a lost run that may still attach
  # again, its inline confirm, "Cancelling" until the exit, and the line after it, for
  # each way the run ended.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [with_domain: 2]
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Repo
  alias Apiary.Runs.{Projector, Run}
  alias ApiaryWeb.Format

  @moduletag needs: :observability

  @question_sub "The agent stops at its next report to Qory Apiary, and the run changes nothing more. What it already sent stays, marked as from a cancelled run."

  setup :register_and_log_in_user

  defp page(conn, scope, run),
    do: live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

  defp name(scope), do: hd(String.split(scope.user.email, "@"))

  defp marked!(run, scope, at \\ DateTime.utc_now()) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [cancel_requested_at: at, cancel_requested_by_id: scope.user.id]
      )

    at
  end

  defp lost!(run, changes) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", lost_at: DateTime.utc_now(), silenced_at: nil] ++ changes
      )

    :ok
  end

  defp exited!(run, data) do
    event_fixture(run, 60, "run.exited", data)
    {:ok, run} = Projector.project(Repo.get!(Run, run.id))
    run
  end

  # The words of a line: without what only a screen reader reads, and without the
  # avatar's letter, which it hides from one.
  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r{<span class="sr-only">[^<]*</span>}, "")
    |> String.replace(~r{<span aria-hidden="true"[^>]*>[^<]*</span>}, "")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> squish()
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  test "Cancel run opens its confirm; Don't cancel closes it; Cancel run cancels", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope)
    {:ok, lv, _html} = page(conn, scope, run)

    assert has_element?(lv, "#run-meta #run-cancel", "Cancel run")
    refute has_element?(lv, "#run-cancel-confirm")

    lv |> element("#run-cancel") |> render_click()
    assert text(lv, "#run-cancel-confirm-question") == "Cancel run #{run.number}?"
    assert text(lv, "#run-cancel-confirm-sub") == @question_sub
    assert has_element?(lv, "#run-cancel-confirm-cancel", "Don't cancel")
    refute has_element?(lv, "#run-cancel")

    lv |> element("#run-cancel-confirm-cancel") |> render_click()
    refute has_element?(lv, "#run-cancel-confirm")
    refute Run.cancel_requested?(Repo.get!(Run, run.id))

    lv |> element("#run-cancel") |> render_click()
    lv |> element("#run-cancel-confirm-yes") |> render_click()

    assert Run.cancel_requested?(Repo.get!(Run, run.id))
    assert text(lv, "#run-meta #run-state") == "Cancelling"
    refute has_element?(lv, "#run-cancel")
    refute has_element?(lv, "#run-cancel-confirm")
    # Until its exit, no line: the state says it.
    refute has_element?(lv, "#run-cancelled")
  end

  test "a run with its exit has no Cancel run", %{conn: conn, scope: scope} do
    run = started_run(scope, %{}, exit: %{"state" => "succeeded", "exit_code" => 0})
    {:ok, lv, _html} = page(conn, scope, run)
    refute has_element?(lv, "#run-cancel")
  end

  test "after the cancel's exit: who cancelled it and when", %{conn: conn, scope: scope} do
    run = started_run(scope)
    at = marked!(run, scope)

    exited!(run, %{
      "state" => "cancelled",
      "reason" => "cancelled_by_member",
      "exit_code" => -1,
      "signal" => "SIGTERM"
    })

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") ==
             "Cancelled by #{name(scope)} (you) at #{Format.time(at, seconds: true)}"

    assert has_element?(lv, "#run-cancelled abbr[data-tip='#{scope.user.email} (you)']")
  end

  test "after another exit: that nothing it sent counts", %{conn: conn, scope: scope} do
    run = started_run(scope)
    at = marked!(run, scope)
    exited!(run, %{"state" => "succeeded", "exit_code" => 0})

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") ==
             "Cancelled by #{name(scope)} (you) at #{Format.time(at, seconds: true)}. " <>
               "The run ended completed before it stopped; nothing it sent counts."
  end

  test "a deleted account reads Former member", %{conn: conn, scope: scope} do
    run = started_run(scope)
    at = marked!(run, scope)
    exited!(run, %{"state" => "failed", "exit_code" => 1})

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [cancel_requested_by_id: nil])

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") ==
             "Cancelled by Former member at #{Format.time(at, seconds: true)}. " <>
               "The run ended failed before it stopped; nothing it sent counts."
  end

  test "while the machine is quiet: when it last reported", %{conn: conn, scope: scope} do
    run = started_run(scope, %{}, heartbeat: {600, 30, 30})
    marked!(run, scope)
    heard = Repo.get!(Run, run.id).last_heartbeat_at

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-meta #run-state") == "Cancelling"

    assert text(lv, "#run-cancelled") ==
             "No report from the machine since #{Format.time(heard, seconds: true)}. " <>
               "The run ends at its next report, or is marked lost once its heartbeats stop."
  end

  test "a lost run that may still attach again reads as running, not as ended lost", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope)
    marked!(run, scope)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", lost_at: DateTime.utc_now(), backstop_at: later, silenced_at: nil]
      )

    refute Run.ended?(Repo.get!(Run, run.id))

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-meta #run-state") == "Cancelling"
    refute render(lv) =~ "before it stopped"
  end

  test "a lost run that may still attach again has Cancel run until it is lost for good", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    lost!(run, backstop_at: later)

    {:ok, lv, _html} = page(conn, scope, run)
    assert has_element?(lv, "#run-meta #run-cancel", "Cancel run")

    lv |> element("#run-cancel") |> render_click()
    assert text(lv, "#run-cancel-confirm-question") == "Cancel run #{run.number}?"
    lv |> element("#run-cancel-confirm-yes") |> render_click()

    cancelled = Repo.get!(Run, run.id)
    assert Run.cancel_requested?(cancelled)
    assert cancelled.state == "lost"
    assert text(lv, "#run-meta #run-state") == "Cancelling"
    refute has_element?(lv, "#run-cancel")

    assert [_entry] =
             Repo.all(
               from e in Apiary.Audit.Entry,
                 where: e.subject_id == ^run.id and e.action == "run.cancel"
             )

    # Past its backstop, a lost run that nobody cancelled has ended: no Cancel run.
    other = started_run(scope)
    lost!(other, backstop_at: DateTime.add(DateTime.utc_now(), -1, :second))

    {:ok, lv, _html} = page(conn, scope, other)
    refute has_element?(lv, "#run-cancel")
  end

  test "an open page drops Cancel run once its lost run's backstop passes", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope)
    backstop = DateTime.add(DateTime.utc_now(), 2, :second)
    lost!(run, backstop_at: backstop)

    {:ok, lv, _html} = page(conn, scope, run)
    assert has_element?(lv, "#run-cancel")

    # The backstop passes, which changes no row; the page's timer checks the run again.
    Process.sleep(max(DateTime.diff(backstop, DateTime.utc_now(), :millisecond) + 50, 0))
    send(lv.pid, :quiet_tick)
    refute has_element?(lv, "#run-cancel")
  end

  @tag needs: [:observability, :factory]
  test "a cancel while the run was pushing its changes", %{conn: conn, scope: scope} do
    run = started_run(scope)
    at = marked!(run, scope)

    event_fixture(run, 50, "run.step_started", %{
      "step" => 1,
      "name" => "push work to git.example.com/acme/web-shop",
      "kind" => "push"
    })

    exited!(run, %{
      "state" => "cancelled",
      "reason" => "cancelled_by_member",
      "exit_code" => -1,
      "signal" => "SIGTERM"
    })

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") =~
             "Cancelled by #{name(scope)} (you) at #{Format.time(at, seconds: true)}, " <>
               "while the run was pushing its changes."

    # Its gateway reported no write.
    assert written(lv) == ["No push to this run's repositories was recorded."]
  end

  @app "0123456789abcdef0123456789abc0a1"
  @lib "0123456789abcdef0123456789abc0b2"
  @docs "0123456789abcdef0123456789abc0c3"

  # The run's target and its further repositories, as Qory labels a run.
  @targets %{
    "forge" => "git.example",
    "repository" => "example-org/app",
    "repositories" => "example-org/app,example-org/lib,example-org/docs"
  }

  defp write(sequence, path, state, request_id),
    do:
      {sequence, "run.target_write",
       %{"system" => "git.example", "path" => path, "state" => state, "request_id" => request_id}}

  defp push_step!(run),
    do:
      event_fixture(run, 10, "run.step_started", %{
        "step" => 1,
        "name" => "push work to git.example",
        "kind" => "push"
      })

  defp cancelled!(run, writes) do
    events_fixture(run, writes)

    exited!(run, %{
      "state" => "cancelled",
      "reason" => "cancelled_by_member",
      "exit_code" => -1
    })
  end

  # The lines after the cancel's sentence, each repository's or that no push was recorded.
  defp written(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-cancelled [id^=run-cancelled-written-]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))
  end

  @tag needs: [:observability, :factory]
  test "a cancel during the push: each repository pushed, or that may have been", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope, @targets)
    marked!(run, scope)
    push_step!(run)

    cancelled!(run, [
      write(11, "example-org/app", "started", @app),
      write(12, "example-org/app", "changed", @app),
      write(13, "example-org/docs", "started", @docs),
      write(14, "example-org/docs", "refused", @docs),
      # The gateway stopped before it ended this write.
      write(15, "example-org/lib", "started", @lib)
    ])

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") =~ "while the run was pushing its changes."

    assert written(lv) == [
             "example-org/app was pushed.",
             "example-org/lib may have been pushed."
           ]
  end

  @tag needs: [:observability, :factory]
  test "a cancel during the push whose every write was refused: no push recorded", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope, @targets)
    marked!(run, scope)
    push_step!(run)

    cancelled!(run, [
      write(11, "example-org/app", "started", @app),
      write(12, "example-org/app", "refused", @app)
    ])

    {:ok, lv, _html} = page(conn, scope, run)
    assert written(lv) == ["No push to this run's repositories was recorded."]
  end

  @tag needs: [:observability, :factory]
  test "a write the run was cut during says the run was pushing, without the push step", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope, @targets)
    at = marked!(run, scope)

    cancelled!(run, [
      write(11, "example-org/app", "started", @app),
      write(12, "example-org/app", "cut", @app)
    ])

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") =~
             "Cancelled by #{name(scope)} (you) at #{Format.time(at, seconds: true)}, " <>
               "while the run was pushing its changes."

    assert written(lv) == ["example-org/app may have been pushed."]
  end

  @tag needs: [:observability, :factory]
  test "a write to a place that is none of the run's targets has no line", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope, @targets)
    marked!(run, scope)
    push_step!(run)

    cancelled!(run, [
      write(11, "example-org/app", "started", @app),
      write(12, "example-org/app", "changed", @app),
      # A path the gateway kept as sent, and a repository the run does not name.
      write(13, "example-org/%2e%2e/app.git", "changed", @lib),
      write(14, "other-org/tool", "cut", @docs)
    ])

    {:ok, lv, _html} = page(conn, scope, run)
    assert written(lv) == ["example-org/app was pushed."]
  end

  @tag needs: [:observability, :factory]
  test "with writes to other places alone, no push to the run's repositories was recorded", %{
    conn: conn,
    scope: scope
  } do
    run = started_run(scope, @targets)
    marked!(run, scope)
    push_step!(run)
    cancelled!(run, [write(11, "other-org/tool", "changed", @app)])

    {:ok, lv, _html} = page(conn, scope, run)
    assert written(lv) == ["No push to this run's repositories was recorded."]
  end

  # The example domain pushes (`Apiary.Lingo.Domain.pushes?/1`). Its run has no labels of
  # a target, so the line records no push to the run's targets.
  test "in another domain that pushes: the writes are kept, and the line records no push", %{
    conn: conn,
    scope: scope
  } do
    scope = with_domain(scope, "example")
    run = started_run(scope)
    at = marked!(run, scope)
    push_step!(run)
    cancelled!(run, [write(11, "queue/billing", "changed", @app)])

    {:ok, lv, _html} = page(conn, scope, run)

    assert text(lv, "#run-cancelled") =~
             "Cancelled by #{name(scope)} (you) at #{Format.time(at, seconds: true)}, " <>
               "while the run was pushing its changes."

    assert written(lv) == ["No push to this run's targets was recorded."]
    assert [%{state: "changed"}] = Apiary.Runs.TargetWrite.of_run(run)
  end

  test "a run with no mark has no cancel line, whatever it wrote", %{conn: conn, scope: scope} do
    run = started_run(scope)

    events_fixture(run, [write(11, "example-org/app", "changed", @app)])
    exited!(run, %{"state" => "cancelled", "reason" => "stopped", "exit_code" => -1})

    {:ok, lv, _html} = page(conn, scope, run)
    refute has_element?(lv, "#run-cancelled")
  end
end

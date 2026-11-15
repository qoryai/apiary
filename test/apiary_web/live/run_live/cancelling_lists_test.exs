defmodule ApiaryWeb.RunLive.CancellingListsTest do
  # A run a member cancelled reads "Cancelling" in place of its state until it ends
  # (`Apiary.Runs.Cancel.cancelling?/1`), wherever a page lists the run's state: the runs
  # list's row and preview, the run page's Details, a target's last runs, the targets
  # list, the runs that reached a destination, and Search or jump to.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  alias Apiary.{Repo, Targets}
  alias Apiary.Runs.Run
  alias ApiaryWeb.{RunComponents, TargetComponents}

  @moduletag needs: :observability

  setup :register_and_log_in_user

  defp marked!(run, scope) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [cancel_requested_at: DateTime.utc_now(), cancel_requested_by_id: scope.user.id]
      )

    Repo.get!(Run, run.id)
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp values(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp boxes(view), do: values(view, "#filter-state-form input[name='state[]']")

  defp families(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#filter-state-form input[name^=family_]")
    |> LazyHTML.attribute("data-family")
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "the runs list's row and preview read Cancelling, a running run Running", %{
    conn: conn,
    scope: scope
  } do
    cancelling = scope |> started_run(shop()) |> marked!(scope)
    running = started_run(scope, shop(), ago: 120)

    view = open(conn, workspace_path(scope, "/runs?run=#{cancelling.number}"))
    render_hook(view, "viewport", %{"wide" => true})
    render_async(view)

    assert text(view, "#run-#{cancelling.public_id} .q-rl-st") == "Cancelling"
    assert text(view, "#run-#{running.public_id} .q-rl-st") == "Running"
    assert text(view, "#runs-preview .q-pv-h .q-st-w") == "Cancelling"
  end

  test "the state filter finds a cancelling run under Cancelling, not under Running", %{
    conn: conn,
    scope: scope
  } do
    cancelling = scope |> started_run(shop()) |> marked!(scope)
    running = started_run(scope, shop(), ago: 120)

    view = open(conn, workspace_path(scope, "/runs"))

    # Cancelling is an alive state, after Running, with its count.
    assert text(view, "#filter-state-form") =~ "Running 1 Cancelling 1 Ended well"

    view = open(conn, workspace_path(scope, "/runs?state=cancelling"))
    assert has_element?(view, "#run-#{cancelling.public_id}")
    refute has_element?(view, "#run-#{running.public_id}")

    assert has_element?(
             view,
             "#filter-state-form input[name='state[]'][value=cancelling][checked]"
           )

    view = open(conn, workspace_path(scope, "/runs?state=running"))
    assert has_element?(view, "#run-#{running.public_id}")
    refute has_element?(view, "#run-#{cancelling.public_id}")

    # The Alive view has the cancelling run, and its count says so.
    view = open(conn, workspace_path(scope, "/runs"))
    assert text(view, "#runs-view-alive") == "Alive 2"
  end

  test "what the reader types in the State section keeps the states whose word contains it",
       %{conn: conn, scope: scope} do
    scope |> started_run(shop()) |> marked!(scope)
    started_run(scope, shop(), ago: 120)

    narrow = fn view, typed ->
      view
      |> form("#filter-state-narrow", %{"_filter" => "state", "q" => typed})
      |> render_change()

      render_async(view)
    end

    view = open(conn, workspace_path(scope, "/runs"))

    assert boxes(view) ==
             ~w(queued pending running cancelling completed cancelled paused failed lost)

    assert families(view) == ~w(alive ended_well cancelled paused ended_badly)

    narrow.(view, "cancelli")
    assert boxes(view) == ["cancelling"]
    assert families(view) == ["alive"]
    assert has_element?(view, "#filter-state-search[value=cancelli]")

    # In any case, as the other sections; "canc" is also in Cancelled.
    narrow.(view, "CANC")
    assert boxes(view) == ~w(cancelling cancelled)
    assert families(view) == ~w(alive cancelled)

    narrow.(view, "nothing")
    assert boxes(view) == []
    assert text(view, "#filter-state-form") == "Nothing matches"

    # A chosen state stays, so that ticking another keeps it.
    view = open(conn, workspace_path(scope, "/runs?state=running"))
    narrow.(view, "cancelli")
    assert boxes(view) == ~w(running cancelling)
  end

  test "the state filter finds a lost run that may still attach under Cancelling, not Lost",
       %{conn: conn, scope: scope} do
    run = scope |> started_run(shop()) |> marked!(scope)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", backstop_at: later, silenced_at: nil]
      )

    view = open(conn, workspace_path(scope, "/runs?state=cancelling"))
    assert has_element?(view, "#run-#{run.public_id}")

    view = open(conn, workspace_path(scope, "/runs?state=lost"))
    refute has_element?(view, "#run-#{run.public_id}")

    view = open(conn, workspace_path(scope, "/runs"))
    assert text(view, "#runs-view-ended-badly") == "Ended badly 0"
    assert text(view, "#runs-view-alive") == "Alive 1"

    # Once lost for good, it is lost.
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [silenced_at: DateTime.utc_now()]
      )

    view = open(conn, workspace_path(scope, "/runs?state=lost"))
    assert has_element?(view, "#run-#{run.public_id}")
    view = open(conn, workspace_path(scope, "/runs?state=cancelling"))
    refute has_element?(view, "#run-#{run.public_id}")
  end

  test "a cancelled run whose exit arrived reads Cancelled in the list", %{
    conn: conn,
    scope: scope
  } do
    run =
      scope
      |> started_run(shop(), exit: %{"state" => "cancelled", "reason" => "cancelled_by_member"})
      |> marked!(scope)

    view = open(conn, workspace_path(scope, "/runs"))
    assert text(view, "#run-#{run.public_id} .q-rl-st") == "Cancelled"
  end

  test "the run page's Details read Cancelling", %{conn: conn, scope: scope} do
    run = scope |> started_run(shop()) |> marked!(scope)

    view = open(conn, workspace_path(scope, "/runs/#{run.number}"))
    assert text(view, "#run-facts .q-sdot") == "Cancelling"
  end

  test "a target's last runs and the targets list read Cancelling", %{
    conn: conn,
    scope: scope
  } do
    run = scope |> started_run(shop()) |> marked!(scope)
    target = Targets.get(scope, "github.example", "acme/shop")

    view = open(conn, TargetComponents.target_path(scope, target))
    assert text(view, "#target-last-runs-#{run.id} .q-sdot") == "Cancelling"

    view = open(conn, workspace_path(scope, "/targets"))
    # The row's last run, under the path on a phone and in its column on a wide screen.
    assert has_element?(view, "#targets .q-tgt-lw", "Cancelling")
    assert has_element?(view, "#targets .q-tgt-last .sr-only", "Cancelling")
    refute has_element?(view, "#targets .q-tgt-last", "Running")
  end

  test "the targets list reads a lost run that may still attach as Cancelling, and one lost for good as Lost",
       %{scope: scope} do
    run = scope |> started_run(shop()) |> marked!(scope)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", backstop_at: later, silenced_at: nil]
      )

    assert [%{last: %{state: "lost", cancelling: true}}] = Targets.page(scope, %{}).rows

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [silenced_at: DateTime.utc_now()]
      )

    assert [%{last: %{state: "lost", cancelling: false}}] = Targets.page(scope, %{}).rows
  end

  test "the targets list reads a lost run that may still attach as Lost once its events are pruned",
       %{scope: scope} do
    run = scope |> started_run(shop()) |> marked!(scope)
    now = DateTime.utc_now()

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", backstop_at: DateTime.add(now, 3600, :second), silenced_at: nil]
      )

    assert [%{last: %{state: "lost", cancelling: true}}] = Targets.page(scope, %{}).rows

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [events_pruned_at: now])

    assert [%{last: %{state: "lost", cancelling: false}}] = Targets.page(scope, %{}).rows
  end

  test "the runs that reached a destination read Cancelling", %{conn: conn, scope: scope} do
    run =
      scope
      |> started_run(shop(), egress: [%{"host" => "registry.example"}])
      |> marked!(scope)

    view = open(conn, workspace_path(scope, "/network"))
    id = RunComponents.destination_id(%{host: "registry.example", port: 443, path: ""})
    view |> element("##{id}-toggle") |> render_click()
    render_async(view)

    assert text(view, "##{id}-run-#{run.public_id} .q-st-w") == "Cancelling"
  end

  test "Search or jump to says Cancelling for a run with no target", %{
    conn: conn,
    scope: scope
  } do
    run = scope |> started_run() |> marked!(scope)

    answer =
      conn
      |> put_req_header("accept", "application/json")
      |> get(workspace_path(scope, "/jump"), %{"q" => run.public_id})
      |> json_response(200)

    runs = Enum.find(answer["groups"], &(&1["label"] == "Runs"))
    assert [%{"detail" => "Cancelling"}] = runs["items"]
  end
end

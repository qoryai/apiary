defmodule ApiaryWeb.RunLive.ShowAboutWithoutFactoryTest do
  # A reader who may not read the work items (`work_item.read`, of the feature `factory`):
  # the header's work item is the same words as the runs list's, with no link. Not async:
  # the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures, only: [queue_run!: 3]
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 2]

  alias Apiary.Runs.Projector

  @moduletag with_features: [:observability, :security]

  setup :register_and_log_in_user

  test "the header's work item: #N and its title, with no link", %{conn: conn, scope: scope} do
    work_item = work_item_fixture(scope, %{title: "Add currency to orders"})
    run = run_fixture(scope)
    events_fixture(run, [{1, "run.started", started_data(%{"about" => %{"kind" => "explore"}})}])
    {:ok, run} = Projector.project(run)
    queue_run!(scope, run, work_item: work_item)

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    label = "##{work_item.number} Add currency to orders"

    assert has_element?(lv, ~s(#run-about > span#run-work-item:first-child[title="#{label}"]))
    assert has_element?(lv, "#run-work-item > span.hero-rectangle-stack-micro")

    assert lv
           |> element("#run-work-item")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text()
           |> String.trim() ==
             label

    refute has_element?(lv, "a#run-work-item")
    refute has_element?(lv, ~s(a[href*="/work/"]))
  end
end

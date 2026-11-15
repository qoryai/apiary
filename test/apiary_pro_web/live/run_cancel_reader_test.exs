defmodule ApiaryProWeb.RunCancelReaderTest do
  # Cancel run shows only to a person who may cancel the run (`run.cancel`): a person of a
  # client's operator, who reads the client and changes nothing there, has no Cancel run
  # on a running run's page (`ApiaryWeb.RunLive.Show`) or on its work item
  # (`ApiaryWeb.WorkItemLive.Show`). The client's owner has it on both.
  # Not async: the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures

  alias Apiary.{Access, Repo}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem
  alias ApiaryPro.OperatorsFixtures

  @moduletag with_features: Apiary.Features.all()

  setup do
    operator = OperatorsFixtures.operator_fixture(%{organisation_name: "Hive Ops"})
    client = OperatorsFixtures.client_fixture(operator.scope, "Acme")
    owner = client.owner.scope

    pool = pool_fixture(owner)
    %{access_key: key} = enrolled_key_fixture(owner, pool)
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(owner, key)
    run = Repo.get!(Run, run.id)
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    place = "/#{client.organisation.slug}/#{client.workspace.slug}"

    %{
      people: %{reader: operator.user, owner: client.owner.user},
      reader_scope: client.scope,
      run: run,
      run_page: "#{place}/runs/#{run.number}",
      work_item_page: "#{place}/work/#{work_item.number}/explore"
    }
  end

  defp open(conn, user, path) do
    {:ok, lv, _html} = live(log_in_user(conn, user), path)
    lv
  end

  test "the operator's person may not cancel the client's run", ctx do
    refute Access.can?(ctx.reader_scope, :"run.cancel", ctx.run)
  end

  test "the run page has Cancel run for the owner and none for the reader", ctx do
    assert has_element?(open(ctx.conn, ctx.people.owner, ctx.run_page), "#run-cancel")
    refute has_element?(open(ctx.conn, ctx.people.reader, ctx.run_page), "#run-cancel")
  end

  test "the work item has Cancel run for the owner and none for the reader", ctx do
    button = "#work-item-explore-run-cancel"
    assert has_element?(open(ctx.conn, ctx.people.owner, ctx.work_item_page), button)
    refute has_element?(open(ctx.conn, ctx.people.reader, ctx.work_item_page), button)
  end
end

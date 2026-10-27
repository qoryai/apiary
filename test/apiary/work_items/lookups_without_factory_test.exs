defmodule Apiary.WorkItems.LookupsWithoutFactoryTest do
  # The lookups of a work item, its comments, the Work items list, its Filter menu's
  # values and the sidebar's count on an instance without the factory feature: nothing, to
  # an owner too, no comment written, and no test work item made. The features are the
  # node's, so this module is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems

  @tag with_features: [:observability]
  test "find no work item, list none, and take no comment" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)

    # One waits at Confirm for its owner, the reader.
    confirm = work_item_fixture(scope)
    %{dispatch_run: dispatch_run} = explore_run_fixture(confirm, result: understood_result())
    Apiary.Dispatches.Settle.settle(dispatch_run.id)

    assert WorkItems.get_by_number(scope, work_item.number) == nil
    assert WorkItems.get_by_public_id(scope, work_item.public_id) == nil

    ticket_id = Repo.get!(Apiary.Sources.Item, work_item.item_id).public_id
    assert WorkItems.get_for_ticket(scope, ticket_id) == nil

    assert WorkItems.list_comments(scope, work_item) == []
    assert WorkItems.count_comments(scope, work_item) == 0
    assert WorkItems.thread(scope, work_item) == []
    assert WorkItems.comment(scope, work_item, "Seen on staging") == {:error, :not_found}
    assert WorkItems.delete_comment(scope, "cm_0123456789abcdef") == {:error, :not_found}

    counts = %{open: 0, you: 0, declined: 0, closed: 0}

    stages = %{
      explore: 0,
      confirm: 0,
      shape: 0,
      exploring: 0,
      answers: 0,
      no_result: 0,
      waiting: 0,
      waiting_you: 0,
      ready: 0
    }

    assert WorkItems.list_work_items(scope) == %{
             rows: [],
             counts: counts,
             stages: stages,
             first: 1,
             next: nil,
             prev: nil
           }

    assert WorkItems.list_bands(scope) == %{
             bands: %{explore: [], confirm: [], shape: []},
             counts: counts,
             stages: stages
           }

    assert WorkItems.list_filter_values(scope, :owner) == []
    assert WorkItems.list_filter_values(scope, :collection) == []
    assert WorkItems.count_waiting_on(scope) == 0
  end

  @tag with_features: [:observability]
  test "make no test work item and queue no run" do
    %{scope: scope} = sign_up_fixture()

    assert WorkItems.take_in_test(scope, "Hello! Where are you running?") ==
             {:error, :not_found}

    assert Repo.aggregate(Apiary.WorkItems.WorkItem, :count) == 0
    assert Repo.aggregate(Apiary.Dispatches.DispatchRun, :count) == 0
  end
end

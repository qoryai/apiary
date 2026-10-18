defmodule Apiary.WorkItems.LookupsWithoutFactoryTest do
  # The lookups of a work item, its comments and the Work items list on an instance
  # without the factory feature: nothing, to an owner too, and no comment written. The features are the node's, so this module is not
  # async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems

  @tag with_features: [:observability]
  test "find no work item, list none, and take no comment" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)

    assert WorkItems.get_by_number(scope, work_item.number) == nil
    assert WorkItems.get_by_public_id(scope, work_item.public_id) == nil

    ticket_id = Repo.get!(Apiary.Sources.Item, work_item.item_id).public_id
    assert WorkItems.get_for_ticket(scope, ticket_id) == nil

    assert WorkItems.list_comments(scope, work_item) == []
    assert WorkItems.count_comments(scope, work_item) == 0
    assert WorkItems.thread(scope, work_item) == []
    assert WorkItems.comment(scope, work_item, "Seen on staging") == {:error, :not_found}
    assert WorkItems.delete_comment(scope, "cm_0123456789abcdef") == {:error, :not_found}

    assert WorkItems.list_work_items(scope) == %{
             rows: [],
             counts: %{open: 0, you: 0, declined: 0, closed: 0},
             next: nil,
             prev: nil
           }
  end
end

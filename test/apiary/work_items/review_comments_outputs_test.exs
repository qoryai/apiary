defmodule Apiary.WorkItems.ReviewCommentsOutputsTest do
  # Review comments read by the type they are on. Versions restart per artifact, so the
  # tests of a shared number have versions of two types with one number, and a review
  # comment on one type never reads as of the other's take in or version.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, WorkItems}
  alias Apiary.Explore.ReviewComments
  alias Apiary.WorkItems.{Explore, ExploreView, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @other "explainer"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # Explore's outputs are the proposal and `types`; `gate`, Explore's gate.
  defp process!(scope, types \\ [@other], gate \\ nil) do
    document = Processes.default_document("software")
    [explore | rest] = document["stages"]
    extra = Enum.map(types, &%{"type" => &1, "required" => false})
    explore = Map.update!(explore, "outputs", &(&1 ++ extra))
    explore = if gate, do: Map.put(explore, "gate", gate), else: explore

    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{document | "stages" => [explore | rest]})
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  # The newest run pushes each of `types` in order, replies to the open review comments
  # where `reply?`, and ends.
  defp ran!(work_item, types, reply? \\ false) do
    end_run!(work_item, fn run, registered ->
      Enum.each(types, &push!(run, work_item, &1))
      if reply?, do: reply_as_run!(run, registered)
    end)
  end

  defp push!(run, work_item, type, name \\ "main") do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        reload(work_item),
        type,
        [file(type)],
        name: name,
        stage_id: run.stage_id
      )

    version
  end

  # A PNG of one pixel.
  defp file("screenshot"),
    do: %{
      filename: "a.png",
      content_type: "image/png",
      binary:
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        )
    }

  defp file("review-comments"), do: ReviewComments.file(%{"review_comments" => []})

  defp file(type),
    do: %{filename: "#{type}.md", content_type: "text/markdown", binary: "## #{type}"}

  # Take in 2 of `work_item`, closed and taken in again through `ticket`.
  defp taken_in_again!(scope, work_item, ticket) do
    {:ok, closed} = WorkItems.close(scope, work_item)
    {:ok, _again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})
    reload(closed)
  end

  defp first!(scope) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    {reload(work_item), ticket}
  end

  defp comments(work_item) do
    case ReviewComments.newest(reload(work_item)) do
      {_version, document} -> ReviewComments.entries(document)
      nil -> nil
    end
  end

  defp shown(work_item),
    do: ExploreView.explore(reload(work_item), DateTime.utc_now()).review_comments

  describe "a version number two types share" do
    test "a comment on the proposal of an earlier take in is not the other type's", %{
      scope: scope
    } do
      process!(scope)
      {work_item, ticket} = first!(scope)

      # Take in 1 has the proposal at versions 1 and 2, and the review comment is on 2.
      work_item = ran!(work_item, ["proposal", "proposal"])
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the rule.")

      # Take in 2 has the other type at version 2, the same number, and the proposal at 3.
      work_item =
        scope |> taken_in_again!(work_item, ticket) |> ran!(["proposal", @other, @other])

      assert %{take_in: 2, status: :confirm} = WorkItems.explore(scope, work_item)
      assert MapSet.member?(Explore.versions(work_item.id, 2), {@other, 2})
      refute MapSet.member?(Explore.versions(work_item.id, 2), {"proposal", 2})

      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :not_waiting}
      assert WorkItems.reply(scope, work_item, 1, "c1", "Not yet.") == {:error, :not_found}
      assert shown(work_item) == []
    end

    test "another type's version with no Markdown leaves the proposal's fold", %{scope: scope} do
      process!(scope, ["screenshot"])
      {work_item, _ticket} = first!(scope)
      work_item = ran!(work_item, ["proposal", "screenshot"])

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the rule.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
      work_item = ran!(work_item, ["proposal"], true)

      assert %{earlier_runs: [%{proposal: %{unread: 1}}]} =
               ExploreView.explore(reload(work_item), DateTime.utc_now())
    end
  end

  describe "a document with review comments on the proposal" do
    test "stays as it is written, and is read, replied to, sent and closed", %{scope: scope} do
      {work_item, _ticket} = first!(scope)
      work_item = ran!(work_item, ["proposal"])

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the rule.")

      assert [%{"id" => "c1", "state" => "open", "on" => on}] = comments(work_item)
      assert on == %{"artifact" => "proposal", "version" => 1}

      assert [%{id: "c1", artifact: "proposal", version: 1, state: :open, replies: []}] =
               shown(work_item)

      {:ok, _} = WorkItems.reply(scope, work_item, 1, "c1", "And the order.")
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      work_item = ran!(work_item, ["proposal"], true)

      assert [%{"state" => "closed", "on" => ^on}] = comments(work_item)

      assert [%{id: "c1", state: :closed, replies: [%{version: 1}, %{run: run, version: 2}]}] =
               shown(work_item)

      assert is_integer(run)
    end
  end
end

defmodule Apiary.WorkItems.RecordsTest do
  # The tables of what a member gives Explore, a take in's confirmation, and of people's
  # comments on the Thread, as the migrations made them, written with no
  # changeset between the write and the database.
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures, only: [user_fixture: 0]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems.{Comment, Confirmation}

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  # Sets `assignments` on the row `id` of `table`, with `params` after the id: $2 onwards.
  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  defp confirmation!(work_item, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Confirmation{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          take_in: 1,
          attempt: 1,
          result: understood_result(),
          confirmed_by_id: work_item.taken_in_by_id,
          confirmed_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp comment!(work_item, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Comment{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          public_id: Apiary.PublicId.generate("cm"),
          author_id: work_item.taken_in_by_id,
          body: "Seen on staging.",
          inserted_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, work_item: work_item_fixture(scope)}
  end

  describe "work_item_confirmations" do
    test "a take in and a run are counted from 1", %{work_item: item} do
      confirmation = confirmation!(item)

      for assignment <- ["take_in = 0", "attempt = 0"] do
        refused("work_item_confirmations_run_check", fn ->
          update!("work_item_confirmations", confirmation.id, assignment)
        end)
      end
    end

    test "the result is a JSON object of 1 MiB at most", %{work_item: item} do
      confirmation = confirmation!(item)

      for value <- [[], "text", %{"text" => String.duplicate("a", 1_048_576)}] do
        refused("work_item_confirmations_result_check", fn ->
          update!("work_item_confirmations", confirmation.id, "result = $2::jsonb", [value])
        end)
      end

      assert %{num_rows: 1} =
               update!("work_item_confirmations", confirmation.id, "result = $2::jsonb", [
                 %{"verdict" => "understood"}
               ])
    end

    test "one confirmation of a take in", %{work_item: item} do
      confirmation!(item)

      assert_raise Ecto.ConstraintError,
                   ~r/work_item_confirmations_work_item_id_take_in_index/,
                   fn ->
                     confirmation!(item, %{attempt: 2})
                   end

      assert confirmation!(item, %{take_in: 2})
    end

    test "a confirmation is of its work item's workspace", %{scope: scope, work_item: item} do
      confirmation = confirmation!(item)
      elsewhere = workspace_fixture(scope.organisation)

      refused("work_item_confirmations_work_item_id_fkey", fn ->
        update!("work_item_confirmations", confirmation.id, "workspace_id = $2", [
          Ecto.UUID.dump!(elsewhere.id)
        ])
      end)
    end
  end

  describe "work_item_comments" do
    test "a comment not deleted has its body, 1 to 4,000 characters", %{work_item: item} do
      comment = comment!(item)

      for {assignment, params} <- [
            {"body = NULL", []},
            {"body = ''", []},
            {"body = $2", [String.duplicate("é", 4001)]}
          ] do
        refused("work_item_comments_body_check", fn ->
          update!("work_item_comments", comment.id, assignment, params)
        end)
      end

      assert %{num_rows: 1} =
               update!("work_item_comments", comment.id, "body = $2", [
                 String.duplicate("é", 4000)
               ])
    end

    test "a deleted comment has no body, and only a deleted one has who deleted it",
         %{work_item: item} do
      comment = comment!(item)

      refused("work_item_comments_body_check", fn ->
        update!("work_item_comments", comment.id, "deleted_at = now()")
      end)

      refused("work_item_comments_deleted_check", fn ->
        update!("work_item_comments", comment.id, "deleted_by_id = author_id")
      end)

      assert %{num_rows: 1} =
               update!(
                 "work_item_comments",
                 comment.id,
                 "deleted_at = now(), body = NULL, deleted_by_id = author_id"
               )

      # The account of who deleted it may go: the line stays, with nobody.
      assert %{num_rows: 1} = update!("work_item_comments", comment.id, "deleted_by_id = NULL")
    end

    test "its public id is cm_ and sixteen characters, and no other comment's", %{work_item: item} do
      comment = comment!(item)

      for id <- ["wi_0123456789abcdef", "cm_0123456789ABCDEF", "cm_0123456789abcdel", "cm_"] do
        refused("work_item_comments_public_id_check", fn ->
          update!("work_item_comments", comment.id, "public_id = $2", [id])
        end)
      end

      assert_raise Ecto.ConstraintError, ~r/work_item_comments_public_id_index/, fn ->
        comment!(item, %{public_id: comment.public_id})
      end
    end

    test "a comment is of its work item's workspace", %{scope: scope, work_item: item} do
      comment = comment!(item)
      elsewhere = workspace_fixture(scope.organisation)

      refused("work_item_comments_work_item_id_fkey", fn ->
        update!("work_item_comments", comment.id, "workspace_id = $2", [
          Ecto.UUID.dump!(elsewhere.id)
        ])
      end)
    end

    test "follows its work item to another workspace, and goes with it", ctx do
      %{scope: scope, work_item: item} = ctx
      comment = comment!(item)
      elsewhere = workspace_fixture(scope.organisation)

      assert %{num_rows: 1} =
               update!("work_items", item.id, "workspace_id = $2", [Ecto.UUID.dump!(elsewhere.id)])

      assert Repo.reload!(comment).workspace_id == elsewhere.id
      Repo.delete!(Repo.reload!(item))
      assert Repo.reload(comment) == nil
    end

    test "stays when its author's or its deleter's account goes, with nobody", %{work_item: item} do
      author = user_fixture()
      deleter = user_fixture()
      comment = comment!(item, %{author_id: author.id})

      deleted =
        comment!(item, %{
          author_id: author.id,
          body: nil,
          deleted_at: DateTime.utc_now(),
          deleted_by_id: deleter.id
        })

      Repo.delete!(author)
      Repo.delete!(deleter)

      assert %Comment{author_id: nil, body: "Seen on staging."} = Repo.reload!(comment)
      assert %Comment{author_id: nil, deleted_by_id: nil, body: nil} = Repo.reload!(deleted)
    end
  end

  describe "a confirmation" do
    test "follow their work item to another workspace of its organisation", ctx do
      %{scope: scope, work_item: item} = ctx
      confirmation = confirmation!(item)
      elsewhere = workspace_fixture(scope.organisation)

      assert %{num_rows: 1} =
               update!("work_items", item.id, "workspace_id = $2", [Ecto.UUID.dump!(elsewhere.id)])

      assert Repo.reload!(confirmation).workspace_id == elsewhere.id
    end

    test "go with their work item", %{work_item: item} do
      confirmation = confirmation!(item)
      Repo.delete!(item)

      assert Repo.reload(confirmation) == nil
    end

    test "stay when the member's account goes, with no member", %{work_item: item} do
      user = user_fixture()
      confirmation = confirmation!(item, %{confirmed_by_id: user.id})
      Repo.delete!(user)

      assert %Confirmation{confirmed_by_id: nil} = Repo.reload!(confirmation)
    end
  end
end

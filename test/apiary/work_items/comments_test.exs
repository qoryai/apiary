defmodule Apiary.WorkItems.CommentsTest do
  # People's comments on a work item's Thread (`Apiary.WorkItems.comment/3`,
  # `delete_comment/2`): each with its row, its entry in the trail and what it tells the
  # pages, and each refusal; and the reads, `list_comments/2`, `count_comments/2` and
  # `thread/3`.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Organisations, Repo, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.{Comment, WorkItem}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, work_item: work_item_fixture(scope)}
  end

  defp entries(action, work_item),
    do:
      Repo.all(
        from e in Entry,
          where: e.action == ^action and e.subject_id == ^work_item.id,
          order_by: [asc: e.inserted_at]
      )

  defp comments(work_item),
    do: Repo.all(from c in Comment, where: c.work_item_id == ^work_item.id)

  defp end_runs!(work_item) do
    Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )
  end

  defp other_workspace_scope(scope),
    do: workspace_scope(scope.user, workspace_fixture(scope.organisation))

  defp subscribe!(scope), do: :ok = WorkItems.subscribe(scope)

  describe "comment/3" do
    test "writes the comment, with its id, author and time, and marks the work item changed",
         ctx do
      before = DateTime.utc_now()

      assert {:ok, %Comment{} = comment} =
               WorkItems.comment(
                 ctx.scope,
                 ctx.work_item,
                 "  Two items at €12.45\r\nare enough.\r\n"
               )

      assert Apiary.PublicId.valid?("cm", comment.public_id)
      assert comment.body == "Two items at €12.45\nare enough."
      assert comment.author_id == ctx.scope.user.id
      assert comment.work_item_id == ctx.work_item.id
      assert comment.workspace_id == ctx.work_item.workspace_id
      assert comment.organisation_id == ctx.work_item.organisation_id
      assert DateTime.compare(comment.inserted_at, before) != :lt
      assert comment.deleted_at == nil

      assert %Comment{body: "Two items at €12.45\nare enough."} =
               Repo.get_by!(Comment, public_id: comment.public_id)

      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      assert DateTime.compare(work_item.updated_at, ctx.work_item.updated_at) == :gt
    end

    test "keeps tab and line feed, and a lone carriage return becomes a line feed", ctx do
      assert {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "a\tb\rc\nd")
      assert comment.body == "a\tb\nc\nd"
    end

    test "its entry in the trail names the comment, never its text", ctx do
      {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "A note for the basket")

      assert [entry] = entries("work_item.comment", ctx.work_item)
      assert entry.subject_kind == "work_item"
      assert entry.details == %{"comment_id" => comment.public_id}
      refute inspect(Map.from_struct(entry)) =~ "A note for the basket"
    end

    test "tells the work item's workspace once it commits", ctx do
      subscribe!(ctx.scope)
      {:ok, _comment} = WorkItems.comment(ctx.scope, ctx.work_item, "Seen on staging")
      public_id = ctx.work_item.public_id
      assert_receive {:work_items_changed, [^public_id]}
    end

    test "on a work item in any state: declined, closed or undone", ctx do
      declined = work_item_fixture(ctx.scope, external_ref: "acme/shop#21")
      end_runs!(declined)
      {:ok, declined} = WorkItems.decline(ctx.scope, declined)

      closed = work_item_fixture(ctx.scope, external_ref: "acme/shop#22")
      {:ok, closed} = WorkItems.close(ctx.scope, closed)

      undone = work_item_fixture(ctx.scope, external_ref: "acme/shop#23")
      {:ok, undone} = WorkItems.undo(ctx.scope, undone)

      for work_item <- [declined, closed, undone] do
        assert {:ok, %Comment{}} = WorkItems.comment(ctx.scope, work_item, "After the end")
      end
    end

    test "refuses a text that is blank, too long or holds a character it may not, writing nothing",
         ctx do
      subscribe!(ctx.scope)

      for {body, error} <- [
            {"", :blank},
            {"  \n\t \r\n", :blank},
            {String.duplicate("a", 4001), {:too_long, 4000}},
            # Past four bytes for each character a comment may have: too long before it is
            # read any further.
            {String.duplicate("😀", 4001), {:too_long, 4000}},
            {String.duplicate("a", 16_001), {:too_long, 4000}},
            {"Two\u0007items", :characters},
            {"Two\u0085items", :characters},
            {"Two\u202Eitems", :characters},
            {"Two\u2066items", :characters},
            {"Two\u200Bitems", :characters},
            {"Two\u2028items", :characters}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WorkItems.comment(ctx.scope, ctx.work_item, body)

        assert Comment.error(changeset) == error, inspect(body)
      end

      assert {:ok, %Comment{}} =
               WorkItems.comment(ctx.scope, ctx.work_item, String.duplicate("😀", 4000))

      assert {:ok, %Comment{}} =
               WorkItems.comment(ctx.scope, ctx.work_item, "👩\u200D💻 builds it")

      assert [_one, _two] = comments(ctx.work_item)
      assert [_one, _two] = entries("work_item.comment", ctx.work_item)
    end

    test "refuses a body that is no text", ctx do
      for body <- [nil, %{}, 1, ["a"]] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WorkItems.comment(ctx.scope, ctx.work_item, body)

        assert Comment.error(changeset) in [nil, :blank]
      end

      assert comments(ctx.work_item) == []
    end

    test "a work item of another workspace or organisation is not found", ctx do
      assert WorkItems.comment(other_workspace_scope(ctx.scope), ctx.work_item, "Hello") ==
               {:error, :not_found}

      %{scope: elsewhere} = sign_up_fixture()
      assert WorkItems.comment(elsewhere, ctx.work_item, "Hello") == {:error, :not_found}

      assert WorkItems.comment(ctx.scope, %WorkItem{id: "not-a-uuid"}, "Hello") ==
               {:error, :not_found}

      assert comments(ctx.work_item) == []
    end

    test "a member removed from the organisation comments no more", ctx do
      member = member_fixture(ctx.scope)
      assert {:ok, _comment} = WorkItems.comment(member.scope, ctx.work_item, "Before")
      {:ok, _} = Organisations.remove_member(ctx.scope, member.membership.id)

      assert {:error, _refused} = WorkItems.comment(member.scope, ctx.work_item, "After")
      assert [_one] = comments(ctx.work_item)
    end
  end

  describe "delete_comment/2" do
    setup ctx do
      author = member_fixture(ctx.scope)
      {:ok, comment} = WorkItems.comment(author.scope, ctx.work_item, "Wrong work item, sorry")
      %{author: author, comment: comment}
    end

    test "its author deletes it: the body goes, and who deleted it and when stay", ctx do
      before = DateTime.utc_now()

      assert {:ok, %Comment{} = deleted} =
               WorkItems.delete_comment(ctx.author.scope, ctx.comment.public_id)

      assert deleted.body == nil
      assert deleted.deleted_by_id == ctx.author.user.id
      assert DateTime.compare(deleted.deleted_at, before) != :lt

      assert %Comment{body: nil, deleted_by_id: by} = Repo.reload!(ctx.comment)
      assert by == ctx.author.user.id
    end

    test "an owner and an admin delete another member's comment", ctx do
      admin = member_fixture(ctx.scope, :admin)
      {:ok, other} = WorkItems.comment(ctx.author.scope, ctx.work_item, "A second one")

      assert {:ok, %Comment{deleted_by_id: owner_id}} =
               WorkItems.delete_comment(ctx.scope, ctx.comment.public_id)

      assert owner_id == ctx.scope.user.id

      assert {:ok, %Comment{deleted_by_id: admin_id}} =
               WorkItems.delete_comment(admin.scope, other.public_id)

      assert admin_id == admin.user.id
    end

    test "a member deletes nobody else's comment, and nothing changes", ctx do
      other = member_fixture(ctx.scope)

      assert WorkItems.delete_comment(other.scope, ctx.comment.public_id) ==
               {:error, :forbidden}

      assert %Comment{body: "Wrong work item, sorry", deleted_at: nil} =
               Repo.reload!(ctx.comment)

      assert entries("work_item.comment_delete", ctx.work_item) == []
    end

    test "its author removed from the organisation deletes it no more", ctx do
      {:ok, _} = Organisations.remove_member(ctx.scope, ctx.author.membership.id)

      assert {:error, _refused} =
               WorkItems.delete_comment(ctx.author.scope, ctx.comment.public_id)

      assert %Comment{deleted_at: nil} = Repo.reload!(ctx.comment)
    end

    test "a comment deleted already is :deleted, with no second entry", ctx do
      assert {:ok, _deleted} = WorkItems.delete_comment(ctx.scope, ctx.comment.public_id)
      assert WorkItems.delete_comment(ctx.scope, ctx.comment.public_id) == {:error, :deleted}
      assert [_one] = entries("work_item.comment_delete", ctx.work_item)
    end

    test "an id that is no comment's, or a comment of another workspace or organisation, is not found",
         ctx do
      for id <- [
            "cm_",
            "not-a-comment",
            nil,
            1,
            %{},
            ctx.work_item.public_id,
            "cm_" <> String.duplicate("a", 16)
          ] do
        assert WorkItems.delete_comment(ctx.scope, id) == {:error, :not_found}, inspect(id)
      end

      assert WorkItems.delete_comment(other_workspace_scope(ctx.scope), ctx.comment.public_id) ==
               {:error, :not_found}

      %{scope: elsewhere} = sign_up_fixture()

      assert WorkItems.delete_comment(elsewhere, ctx.comment.public_id) ==
               {:error, :not_found}

      assert %Comment{deleted_at: nil} = Repo.reload!(ctx.comment)
    end

    test "on a work item in any state", ctx do
      {:ok, _closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert {:ok, _deleted} = WorkItems.delete_comment(ctx.author.scope, ctx.comment.public_id)
    end

    test "its entry names the comment and its author, never the text, and the work item stays as it was",
         ctx do
      updated_at = Repo.get!(WorkItem, ctx.work_item.id).updated_at
      subscribe!(ctx.scope)
      {:ok, _deleted} = WorkItems.delete_comment(ctx.scope, ctx.comment.public_id)

      assert [entry] = entries("work_item.comment_delete", ctx.work_item)
      assert entry.subject_kind == "work_item"

      assert entry.details == %{
               "comment_id" => ctx.comment.public_id,
               "author_id" => ctx.author.user.id
             }

      refute inspect(Map.from_struct(entry)) =~ "Wrong work item"
      assert Repo.get!(WorkItem, ctx.work_item.id).updated_at == updated_at

      public_id = ctx.work_item.public_id
      assert_receive {:work_items_changed, [^public_id]}
    end
  end

  describe "the reads" do
    test "list_comments/2: every comment, deleted ones too, oldest first; count_comments/2 those not deleted",
         ctx do
      {:ok, first} = WorkItems.comment(ctx.scope, ctx.work_item, "First")
      {:ok, second} = WorkItems.comment(ctx.scope, ctx.work_item, "Second")
      {:ok, third} = WorkItems.comment(ctx.scope, ctx.work_item, "Third")
      {:ok, _deleted} = WorkItems.delete_comment(ctx.scope, second.public_id)

      assert [
               %Comment{public_id: p1, body: "First"},
               %Comment{public_id: p2, body: nil},
               %Comment{public_id: p3, body: "Third"}
             ] = WorkItems.list_comments(ctx.scope, ctx.work_item)

      assert [p1, p2, p3] == [first.public_id, second.public_id, third.public_id]
      assert WorkItems.count_comments(ctx.scope, ctx.work_item) == 2
    end

    test "thread/3: Explore's entries and the comments, oldest first, Explore's first at the same moment",
         ctx do
      {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "Seen on staging")
      [taken_in | _] = WorkItems.explore_thread(ctx.scope, ctx.work_item)

      Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
        set: [inserted_at: taken_in.at]
      )

      assert [%{kind: :taken_in}, %{kind: :comment, comment: %Comment{public_id: id}} | _] =
               WorkItems.thread(ctx.scope, ctx.work_item)

      assert id == comment.public_id

      later = DateTime.add(DateTime.utc_now(), 60, :second)
      Repo.update_all(from(c in Comment, where: c.id == ^comment.id), set: [inserted_at: later])

      assert %{kind: :comment, at: ^later} = List.last(WorkItems.thread(ctx.scope, ctx.work_item))
    end

    test "nothing to a person who may not read the work item there", ctx do
      {:ok, _comment} = WorkItems.comment(ctx.scope, ctx.work_item, "Seen on staging")
      %{scope: elsewhere} = sign_up_fixture()

      for scope <- [other_workspace_scope(ctx.scope), elsewhere] do
        assert WorkItems.list_comments(scope, ctx.work_item) == []
        assert WorkItems.count_comments(scope, ctx.work_item) == 0
        assert WorkItems.thread(scope, ctx.work_item) == []
      end
    end

    test "the comments follow their work item to another workspace", ctx do
      {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "Seen on staging")
      there = other_workspace_scope(ctx.scope)

      Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
        set: [workspace_id: there.workspace.id]
      )

      assert Repo.reload!(comment).workspace_id == there.workspace.id
      assert [%Comment{}] = WorkItems.list_comments(there, ctx.work_item)
      assert WorkItems.list_comments(ctx.scope, ctx.work_item) == []
      assert WorkItems.delete_comment(ctx.scope, comment.public_id) == {:error, :not_found}
      assert {:ok, _deleted} = WorkItems.delete_comment(there, comment.public_id)
    end
  end
end

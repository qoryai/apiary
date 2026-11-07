defmodule Apiary.Sources.MemberCommentEchoTest do
  # The comments an adapter sends about a member's comment (`Apiary.Sources.Ingest`): the
  # echo with its comment_id matches the member's comment and stores no second row; a
  # later echo with another ref keeps the first, and one with the ref of another member's
  # posted comment changes neither; a deletion, with the comment_id or by the
  # ref alone, keeps the comment, clears its ref and URL and marks it deleted at the
  # source; a complete set clears a posted member's comment it leaves out and marks none
  # deleted; a comment_id of no member's comment of the item is kept as any comment; and
  # the Backlog is told of each change.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures, only: [item: 1, items_body: 2, comment: 2, key_scope: 1]
  import Apiary.WorkItemsFixtures, only: [source_collection_fixture: 3]

  alias Apiary.{Repo, Sources}
  alias Apiary.Sources.{Comment, Item, Topic, Wire}

  @moduletag needs: :factory

  @url "https://tracker.example.com/comments/"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    key_scope = key_scope(key)
    source_collection_fixture(scope, connection, %{external_ref: "TRK"})
    {:ok, :accepted} = Sources.post_items(key_scope, items_body("TRK", [item("TRK-1")]))
    item = Repo.get_by!(Item, external_ref: "TRK-1")
    %{scope: scope, key_scope: key_scope, item: item}
  end

  # A member's comment on the item, as a take in writes it, then set to `state`, with
  # `ref` where posted.
  defp member(ctx, state \\ :posting, ref \\ nil) do
    {:ok, comment} =
      %Comment{
        organisation_id: ctx.item.organisation_id,
        item_id: ctx.item.id,
        author_id: ctx.scope.user.id
      }
      |> Comment.member_changeset(
        %{body: "Start with the basket.", author_name: "dana", post_state: :posting},
        ~U[2026-10-15 09:00:00Z]
      )
      |> Repo.insert()

    set(comment, state, ref)
  end

  defp set(comment, state, ref) do
    Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
      set: [post_state: state, external_ref: ref, url: ref && @url <> ref]
    )

    Repo.get!(Comment, comment.id)
  end

  # The body, with `comments` (`comment/2`, plus `comment_id` where given), read as the
  # contract has it.
  defp post(ctx, comments, opts \\ []) do
    body = %{
      "version" => 1,
      "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "item_ref" => "TRK-1",
      "comments" => comments
    }

    body =
      case Keyword.get(opts, :since) do
        nil -> body
        since -> Map.put(body, "complete", %{"since" => DateTime.to_iso8601(since)})
      end

    {:ok, read} = Wire.comments(body)
    Sources.post_comments(ctx.key_scope, read)
  end

  defp sent(ref, comment_id, opts \\ []) do
    comment = comment(ref, opts)
    if comment_id, do: Map.put(comment, "comment_id", comment_id), else: comment
  end

  defp rows(ctx),
    do: Repo.all(from c in Comment, where: c.item_id == ^ctx.item.id, order_by: c.inserted_at)

  describe "an echo with the comment_id" do
    test "matches the member's comment: its ref, URL and time, posted, its text kept", ctx do
      for state <- [:posting, :not_posted, :kept] do
        Repo.delete_all(Comment)
        member = member(ctx)
        member = if state == :not_posted, do: failed(member), else: set(member, state, nil)

        at = ~U[2026-10-15 12:00:05Z]
        assert {:ok, :accepted} = post(ctx, [sent("C-31", member.comment_id, updated_at: at)])

        assert [%Comment{} = matched] = rows(ctx)
        assert matched.id == member.id
        assert {matched.post_state, matched.post_failure} == {:posted, nil}
        assert {matched.external_ref, matched.url} == {"C-31", @url <> "C-31"}
        assert matched.source_updated_at == ~U[2026-10-15 12:00:05Z]
        assert {matched.body, matched.author_name} == {"Start with the basket.", "dana"}
        assert matched.author_kind == :person
        assert matched.deleted_at == nil
      end
    end

    test "sent again changes nothing more; with another ref, the first ref stays", ctx do
      member = member(ctx)
      {:ok, :accepted} = post(ctx, [sent("C-31", member.comment_id)])
      first = Repo.get!(Comment, member.id)

      assert {:ok, :accepted} = post(ctx, [sent("C-32", member.comment_id)])
      assert {:ok, :accepted} = post(ctx, [sent("C-32", member.comment_id, deleted: true)])
      assert rows(ctx) == [first]
    end

    test "twice in one body, with two refs, keeps the ref of the first it reads", ctx do
      member = member(ctx)

      assert {:ok, :accepted} =
               post(ctx, [sent("C-31", member.comment_id), sent("C-32", member.comment_id)])

      assert [%Comment{external_ref: "C-31", post_state: :posted}] = rows(ctx)
    end

    test "with the ref of another member's posted comment changes neither, and is accepted",
         ctx do
      posted = member(ctx, :posted, "C-31")
      posting = member(ctx)

      assert {:ok, :accepted} = post(ctx, [sent("C-31", posting.comment_id)])
      assert rows(ctx) == [posted, posting]

      # A body with two echoes with one ref: the body keeps one entry per ref
      # (`Apiary.Sources.Wire.comments/1`), so one of the two comments is posted with the
      # ref, and the other stays as it was.
      Repo.delete_all(Comment)
      first = member(ctx)
      second = member(ctx)

      assert {:ok, :accepted} =
               post(ctx, [sent("C-31", first.comment_id), sent("C-31", second.comment_id)])

      assert [%Comment{external_ref: "C-31", post_state: :posted} = matched] =
               Enum.filter(rows(ctx), &(&1.post_state == :posted))

      assert rows(ctx) -- [matched] == [Enum.find([first, second], &(&1.id != matched.id))]
    end

    test "deletes the row the adapter sent earlier with that ref and no comment_id", ctx do
      member = member(ctx)
      {:ok, :accepted} = post(ctx, [sent("C-31", nil)])
      assert [_member, %Comment{comment_id: nil, external_ref: "C-31"}] = rows(ctx)

      {:ok, :accepted} = post(ctx, [sent("C-31", member.comment_id)])
      assert [%Comment{id: id, external_ref: "C-31", post_state: :posted}] = rows(ctx)
      assert id == member.id
    end

    test "sent deleted keeps the comment, clears its ref and URL, deleted at the source",
         ctx do
      for ref <- [nil, "C-31"] do
        Repo.delete_all(Comment)
        member = member(ctx, if(ref, do: :posted, else: :posting), ref)

        assert {:ok, :accepted} = post(ctx, [sent("C-31", member.comment_id, deleted: true)])
        assert [%Comment{} = cleared] = rows(ctx)
        assert cleared.id == member.id
        assert {cleared.post_state, cleared.post_failure} == {:not_posted, :deleted_at_source}
        assert {cleared.external_ref, cleared.url, cleared.deleted_at} == {nil, nil, nil}
        assert cleared.body == "Start with the basket."
      end
    end
  end

  describe "a comment without comment_id" do
    test "sent deleted with the ref of a posted member's comment clears it", ctx do
      member = member(ctx, :posted, "C-31")
      assert {:ok, :accepted} = post(ctx, [sent("C-31", nil, deleted: true)])

      assert [%Comment{post_state: :not_posted, post_failure: :deleted_at_source} = cleared] =
               rows(ctx)

      assert {cleared.id, cleared.external_ref, cleared.deleted_at} == {member.id, nil, nil}
    end

    test "sent with the ref of a posted member's comment writes nothing over it", ctx do
      member = member(ctx, :posted, "C-31")
      assert {:ok, :accepted} = post(ctx, [sent("C-31", nil, body: "Changed at the source.")])
      assert rows(ctx) == [member]
    end

    test "with the comment_id of no member's comment of the item is kept as any comment", ctx do
      member = member(ctx)
      other_id = "sc_0000000000000000"
      assert {:ok, :accepted} = post(ctx, [sent("C-40", other_id)])

      assert [^member, %Comment{external_ref: "C-40", comment_id: nil, post_state: nil}] =
               rows(ctx)
    end
  end

  describe "a complete set" do
    test "clears a posted member's comment it leaves out, updated before since, and marks none deleted",
         ctx do
      posted = member(ctx, :posted, "C-31")
      later = member(ctx, :posted, "C-33")

      Repo.update_all(from(c in Comment, where: c.id == ^later.id),
        set: [source_updated_at: ~U[2026-10-15 13:00:00Z]]
      )

      named = member(ctx, :posted, "C-32")
      posting = member(ctx)
      kept = member(ctx, :kept)

      assert {:ok, :accepted} = post(ctx, [sent("C-32", nil)], since: ~U[2026-10-15 12:00:00Z])

      assert %Comment{post_state: :not_posted, post_failure: :deleted_at_source} =
               cleared = Repo.get!(Comment, posted.id)

      assert {cleared.external_ref, cleared.url, cleared.deleted_at} == {nil, nil, nil}

      for {comment, state} <- [
            {later, :posted},
            {named, :posted},
            {posting, :posting},
            {kept, :kept}
          ] do
        assert %Comment{post_state: ^state, deleted_at: nil} = Repo.get!(Comment, comment.id)
      end

      assert Repo.get!(Comment, named.id) == named
    end

    test "with no comments at all clears every posted member's comment updated before since",
         ctx do
      posted = member(ctx, :posted, "C-31")
      posting = member(ctx)
      assert {:ok, :accepted} = post(ctx, [], since: ~U[2026-10-15 12:00:00Z])
      assert Repo.get!(Comment, posted.id).post_failure == :deleted_at_source
      assert Repo.get!(Comment, posting.id).post_state == :posting
    end
  end

  test "the Backlog is told of an echo, and of nothing where nothing changed", ctx do
    member = member(ctx)
    Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.scope.workspace.id))
    ticket_id = ctx.item.public_id

    {:ok, :accepted} = post(ctx, [sent("C-31", member.comment_id)])
    assert_receive {:tickets_changed, [^ticket_id]}

    {:ok, :accepted} = post(ctx, [sent("C-32", member.comment_id)])
    refute_receive {:tickets_changed, _ids}, 100
  end

  defp failed(member) do
    Repo.update_all(from(c in Comment, where: c.id == ^member.id),
      set: [post_state: :not_posted, post_failure: :unreachable]
    )

    Repo.get!(Comment, member.id)
  end
end

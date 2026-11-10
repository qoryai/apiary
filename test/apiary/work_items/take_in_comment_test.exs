defmodule Apiary.WorkItems.TakeInCommentTest do
  # A comment at take in (`Apiary.WorkItems.take_in/3`, `take_in_again/3`): written on the
  # ticket's record in the take in's transaction, by the person, with an `sc_` id and no
  # ref: `:posting`, with a `comment` entry after the take in's entry, for a source that
  # takes comments, `:kept` and no entry for any other; none for none or a blank one;
  # refused when too long or with a
  # character a text may not have, and then nothing is written. The ticket's comment list
  # shows it like any comment.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Nodes.Node
  alias Apiary.Sources.{Comment, Topic}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    %{scope: scope, connection: connection, ticket: ticket}
  end

  defp comments(ticket),
    do: Repo.all(from c in Comment, where: c.item_id == ^ticket.id, order_by: c.inserted_at)

  defp work_items, do: Repo.aggregate(WorkItem, :count)

  defp feed_kinds(ticket),
    do: Enum.map(Feed.entries(Repo.get!(Node, ticket.adapter_id)), & &1.kind)

  defp set_comments(ticket, comments),
    do:
      Repo.update_all(from(n in Node, where: n.id == ^ticket.adapter_id),
        set: [comments: comments]
      )

  defp with_email(scope, email), do: %{scope | user: %{scope.user | email: email}}

  defp short(scope), do: scope.user.email |> String.split("@") |> hd()

  describe "a take in with a comment" do
    test "writes it on the ticket's record, by the person, kept, with no ref", ctx do
      body = "Start with the basket.\n\nThe price is wrong too."

      assert {:ok, %WorkItem{}} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: body})

      assert [%Comment{} = comment] = comments(ctx.ticket)
      assert comment.body == body
      assert comment.organisation_id == ctx.scope.organisation.id
      assert comment.author_id == ctx.scope.user.id
      assert comment.author_name == short(ctx.scope)
      assert comment.author_kind == :person
      # The adapter's description has no `comments`: the source takes none.
      assert comment.post_state == :kept
      assert comment.post_failure == nil
      assert comment.body_format == "markdown"
      assert {comment.external_ref, comment.url} == {nil, nil}
      assert comment.deleted_at == nil
      assert Apiary.PublicId.valid?("sc", comment.comment_id)
      assert %DateTime{} = comment.source_created_at
      assert comment.source_updated_at == comment.source_created_at
    end

    test "takes the comment under the string key a form sends, its line breaks line feeds, trimmed",
         ctx do
      {:ok, _work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{
          "comment" => "  \r\nFirst line.\r\n\tSecond line.\r\n  "
        })

      assert [%Comment{body: "First line.\n\tSecond line."}] = comments(ctx.ticket)
    end

    test "writes no comment for none, nil, an empty one or a blank one", ctx do
      for attrs <- [%{}, %{comment: nil}, %{"comment" => ""}, %{comment: " \r\n\t "}] do
        ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
        assert {:ok, %WorkItem{}} = WorkItems.take_in(ctx.scope, ticket.public_id, attrs)
        assert comments(ticket) == [], inspect(attrs)
      end
    end

    test "keeps a comment of 65,000 characters, and refuses one more, writing nothing", ctx do
      longest = String.duplicate("é", 65_000)
      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

      assert WorkItems.take_in(ctx.scope, other.public_id, %{comment: longest <> "e"}) ==
               {:error, :comment_too_long}

      assert work_items() == 0
      assert comments(other) == []
      assert feed_kinds(other) == []

      # Past four bytes a character, refused before it is read.
      assert WorkItems.take_in(ctx.scope, other.public_id, %{
               comment: String.duplicate("a", 260_001)
             }) == {:error, :comment_too_long}

      assert {:ok, _work_item} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: longest})

      assert [%Comment{body: ^longest}] = comments(ctx.ticket)
    end

    test "refuses a comment with a character a text may not have, writing nothing", ctx do
      for text <- ["Look \u0000 here", "Look \u202E here", <<0xFF, 0xFE>>] do
        assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
                 WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: text})

        assert Keyword.has_key?(changeset.errors, :comment)
      end

      assert {:error, %Ecto.Changeset{errors: [comment: _error]}} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: 12})

      assert work_items() == 0
      assert comments(ctx.ticket) == []
    end

    test "checks every other refusal first", ctx do
      closed = backlog_ticket_fixture(ctx.scope, connection: ctx.connection, state: :closed)
      long = String.duplicate("a", 65_001)

      assert WorkItems.take_in(ctx.scope, closed.public_id, %{comment: long}) ==
               {:error, :ticket_closed}
    end

    test "writes no feed entry for it where the source takes no comments, set or absent", ctx do
      for comments <- [nil, false] do
        set_comments(ctx.ticket, comments)
        ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
        {:ok, _work_item} = WorkItems.take_in(ctx.scope, ticket.public_id, %{comment: "Hi."})

        assert [%Comment{post_state: :kept}] = comments(ticket)
        assert feed_kinds(ticket) |> Enum.uniq() == ["work_item"], inspect(comments)
      end
    end

    test "where the source takes comments, writes it posting, with a comment entry after the take in's",
         ctx do
      set_comments(ctx.ticket, true)
      body = "Start with the basket.\n\nThe price is wrong too."

      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: " " <> body <> " "})

      assert [%Comment{post_state: :posting, post_failure: nil} = comment] =
               comments(ctx.ticket)

      assert {comment.external_ref, comment.url} == {nil, nil}

      assert [
               %{kind: "work_item", data: %{"status" => "taken_in"} = taken_in},
               %{kind: "comment", data: entry}
             ] = Feed.entries(Repo.get!(Node, ctx.ticket.adapter_id))

      assert taken_in["work_item_id"] == work_item.public_id

      assert entry == %{
               "comment_id" => comment.comment_id,
               "ref" => ctx.ticket.external_ref,
               "author_name" => short(ctx.scope),
               "body" => body
             }
    end

    test "with no comment, or a blank one, writes no comment entry where the source takes comments",
         ctx do
      set_comments(ctx.ticket, true)

      for attrs <- [%{}, %{comment: " "}] do
        ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
        {:ok, _work_item} = WorkItems.take_in(ctx.scope, ticket.public_id, attrs)
        assert comments(ticket) == []
      end

      assert feed_kinds(ctx.ticket) |> Enum.uniq() == ["work_item"]
    end

    test "sends a message to the work item's page and the Backlog, as a take in does", ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))
      Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.scope.workspace.id))

      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: "Hi."})

      work_item_id = work_item.public_id
      ticket_id = ctx.ticket.public_id
      assert_receive {:work_items_changed, [^work_item_id]}
      assert_receive {:tickets_changed, [^ticket_id]}
    end
  end

  describe "the author's name" do
    defp name_of(ctx, email) do
      ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
      scope = with_email(ctx.scope, email)
      {:ok, _work_item} = WorkItems.take_in(scope, ticket.public_id, %{comment: "Hi."})
      [%Comment{author_name: name}] = comments(ticket)
      name
    end

    test "is the account's short name without the characters a line refuses", ctx do
      assert name_of(ctx, "dana\n\tex\u007Fam\u0085ple\u202E\u0000@example.com") ==
               "danaexample"
    end

    test "is cut to 100 characters", ctx do
      assert name_of(ctx, String.duplicate("é", 150) <> "@example.com") ==
               String.duplicate("é", 100)
    end

    test "is Member when nothing is left, or only spaces", ctx do
      for email <- ["\n\t\u007F@example.com", "\t @example.com", "\u3000@example.com"] do
        assert name_of(ctx, email) == "Member", inspect(email)
      end
    end
  end

  describe "a take in again with a comment" do
    test "writes it, beside the comment of the first take in", ctx do
      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: "First."})

      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      assert {:ok, %WorkItem{take_in: 2}} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
                 "comment" => " Again. "
               })

      assert [first, again] = comments(ctx.ticket)
      assert {first.body, again.body} == {"First.", "Again."}
      assert again.post_state == :kept
      assert again.author_id == ctx.scope.user.id
      assert again.comment_id != first.comment_id
    end

    test "where the source takes comments, writes a comment entry for it", ctx do
      set_comments(ctx.ticket, true)
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      before = Feed.entries(Repo.get!(Node, ctx.ticket.adapter_id))

      {:ok, _again} =
        WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{comment: "Again."})

      assert [%Comment{post_state: :posting} = comment] = comments(ctx.ticket)

      assert [%{kind: "comment", data: %{"comment_id" => id, "body" => "Again."}}] =
               Feed.entries(Repo.get!(Node, ctx.ticket.adapter_id)) -- before

      assert id == comment.comment_id
    end

    test "writes none for a blank one, and nothing for one too long", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, closed} = WorkItems.close(ctx.scope, work_item)

      assert WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
               comment: String.duplicate("a", 65_001)
             }) == {:error, :comment_too_long}

      assert Repo.get!(WorkItem, work_item.id).state == closed.state
      assert comments(ctx.ticket) == []

      assert {:ok, _again} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{comment: "  "})

      assert comments(ctx.ticket) == []
    end
  end

  describe "the ticket's comment list" do
    test "shows the comment like any comment, under the member's name", ctx do
      {:ok, work_item} =
        WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{comment: "Start here."})

      assert %{comments: [shown]} = WorkItems.ticket(ctx.scope, work_item)
      assert shown.author == short(ctx.scope)
      assert shown.body == "Start here."
      assert shown.format == "markdown"
      assert %DateTime{} = shown.at
      assert %{ticket: %{comment_count: 1}} = WorkItems.ticket(ctx.scope, work_item)
    end
  end
end

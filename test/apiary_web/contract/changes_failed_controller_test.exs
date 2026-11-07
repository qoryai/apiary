defmodule ApiaryWeb.Contract.ChangesFailedControllerTest do
  # `POST /v1/work-items/changes/failed`, an adapter reporting that it stopped trying to
  # post a member's comment, through `ApiaryWeb.Contract.AdapterRequest`: the contract's
  # reports, each a signed 204 that marks a comment being posted not posted with its
  # reason; the contract's invalid reports and the time's window; 403 forbidden first; a
  # signed 204 that changes nothing for a comment of no comment entry of the adapter's
  # feed, posted, or marked already; the Backlog told once a comment changes, and an open
  # page of the ticket's work item read again after a report and after an echo; and a
  # comment's way from its take in to a failure, a post again, and the adapter's echo.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [backlog_ticket_fixture: 2]

  alias Apiary.{Edition, Repo, Sources, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Nodes.Node
  alias Apiary.Sources.{Comment, Topic}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/v1/work-items/changes/failed"
  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @invalid %{"error" => "invalid_request"}
  @forbidden %{"error" => "forbidden"}

  # The edition narrows the rights of an adapter's key: its role posts no comments.
  defmodule NoPost do
    @moduledoc false
    def check(_scope, :"source_item.post", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [comments: true])

    %{
      scope: scope,
      adapter: Repo.get!(Node, adapter.id),
      key: key,
      seed: pair.secret,
      connection: connection
    }
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp fixtures(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
    |> Enum.sort()
  end

  defp now_time(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # A ticket taken in with a comment: the comment, being posted.
  defp posting(ctx) do
    ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

    {:ok, _work_item} =
      WorkItems.take_in(ctx.scope, ticket.public_id, %{comment: "Start with the basket."})

    comment = Repo.get_by!(Comment, item_id: ticket.id)
    assert comment.post_state == :posting
    {ticket, comment}
  end

  # A ticket taken in with a comment, as `posting/1` leaves it, with its work item.
  defp taken_in(ctx) do
    ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

    {:ok, work_item} =
      WorkItems.take_in(ctx.scope, ticket.public_id, %{comment: "Start with the basket."})

    {ticket, work_item, Repo.get_by!(Comment, item_id: ticket.id)}
  end

  # The work item's Ticket tab, open for the member who took it in.
  defp ticket_tab(ctx, work_item) do
    conn = log_in_user(build_conn(), ctx.scope.user)
    path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/work/#{work_item.number}/ticket"
    {:ok, view, _html} = live(conn, path)
    view
  end

  # The comment's text changed with no message to any page: the page shows the new text
  # only once a message makes it read the ticket again.
  defp rewrite(comment, body),
    do: Repo.update_all(from(c in Comment, where: c.id == ^comment.id), set: [body: body])

  # The adapter posts the comment as `ref` and sends it back with its `comment_id`.
  defp echo(ctx, ticket, comment, ref) do
    url = "https://tracker.example.com/comments/#{ref}"

    body = %{
      "version" => 1,
      "time" => now_time(),
      "item_ref" => ticket.external_ref,
      "comments" => [
        %{
          "ref" => ref,
          "url" => url,
          "comment_id" => comment.comment_id,
          "author" => %{"name" => "Example integration", "kind" => "automation"},
          "body" => "#{comment.author_name} wrote in Qory Apiary:\n\n#{comment.body}",
          "body_format" => "markdown",
          "created_at" => "2026-11-06T10:00:00Z",
          "updated_at" => "2026-11-06T10:00:00Z"
        }
      ]
    }

    build_conn()
    |> signed_post(ctx.key.key_id, ctx.seed, body,
      target: "/v1/source-items/comments",
      content_type: "application/json",
      delivery: nil
    )
    |> no_content!()

    url
  end

  defp report(comment_id, reason \\ "unreachable", offset \\ 0) do
    %{"version" => 1, "time" => now_time(offset), "comment_id" => comment_id, "reason" => reason}
  end

  defp send_report(ctx, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: @path,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp no_content!(conn) do
    assert conn.status == 204
    assert conn.resp_body == ""
    assert signed_answer?(conn)
  end

  defp states,
    do: Repo.all(from c in Comment, order_by: c.id, select: {c.id, c.post_state, c.post_failure})

  test "each of the contract's reports is a signed 204 that marks the comment not posted", ctx do
    paths = fixtures("changes-failed/*.json")
    assert paths == ~w(changes-failed/not-permitted.json changes-failed/unreachable.json)

    for path <- paths do
      {_ticket, comment} = posting(ctx)
      written = fixture(path)

      body =
        Map.merge(written, %{"time" => now_time(), "comment_id" => comment.comment_id})

      ctx |> send_report(body) |> no_content!()

      assert %Comment{post_state: :not_posted, post_failure: failure} =
               Repo.get!(Comment, comment.id)

      assert Atom.to_string(failure) == written["reason"], path
    end
  end

  test "every reason is kept", ctx do
    for reason <- ~w(item_gone not_permitted too_long unreachable) do
      {_ticket, comment} = posting(ctx)
      ctx |> send_report(report(comment.comment_id, reason)) |> no_content!()
      assert Atom.to_string(Repo.get!(Comment, comment.id).post_failure) == reason
    end
  end

  test "the contract's invalid reports, and a member it does not define, are 400, signed",
       ctx do
    {_ticket, comment} = posting(ctx)
    before = states()

    paths = fixtures("invalid/changes-failed-*.json")
    assert length(paths) == 2

    bodies =
      Enum.map(paths, &Map.put(fixture(&1), "time", now_time())) ++
        [
          Map.put(report(comment.comment_id), "connection_id", ctx.connection.public_id),
          report(comment.comment_id, "deleted_at_source"),
          report(String.upcase(comment.comment_id))
        ]

    for body <- bodies do
      conn = send_report(ctx, body)
      assert json_response(conn, 400) == @invalid, inspect(body)
      assert signed_answer?(conn)
    end

    assert states() == before
  end

  test "a time more than 300 seconds off is 401, unsigned", ctx do
    {_ticket, comment} = posting(ctx)

    for offset <- [-301, 301] do
      conn = send_report(ctx, report(comment.comment_id, "unreachable", offset))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
    end

    assert Repo.get!(Comment, comment.id).post_state == :posting
  end

  test "403 forbidden comes first, for any comment_id, and changes nothing", ctx do
    {_ticket, comment} = posting(ctx)
    Edition.put_test_stub(NoPost)

    for id <- [comment.comment_id, "sc_0000000000000000"] do
      conn = send_report(ctx, report(id))
      assert json_response(conn, 403) == @forbidden
      assert signed_answer?(conn)
    end

    assert Repo.get!(Comment, comment.id).post_state == :posting
  end

  test "a signed 204 changes nothing for a comment of no entry, posted, or marked already",
       ctx do
    {_ticket, kept} = posting(ctx)
    {_ticket, posted} = posting(ctx)
    {_ticket, marked} = posting(ctx)
    {_ticket, elsewhere} = posting(ctx)

    Repo.update_all(from(c in Comment, where: c.id == ^kept.id), set: [post_state: :kept])

    Repo.update_all(from(c in Comment, where: c.id == ^posted.id),
      set: [
        post_state: :posted,
        external_ref: "C-1",
        url: "https://tracker.example.com/comments/C-1"
      ]
    )

    ctx |> send_report(report(marked.comment_id, "item_gone")) |> no_content!()
    before = states()
    entries = Feed.entries(ctx.adapter)

    # Another adapter's key: the comment is of no entry of its feed.
    other = connectable_adapter_fixture()

    ctx
    |> send_report(report(elsewhere.comment_id),
      key_id: other.access_key.key_id,
      seed: other.pair.secret
    )
    |> no_content!()

    for id <- [kept.comment_id, posted.comment_id, marked.comment_id, "sc_0000000000000000"] do
      ctx |> send_report(report(id, "too_long")) |> no_content!()
    end

    assert states() == before
    assert Repo.get!(Comment, marked.id).post_failure == :item_gone
    assert Feed.entries(ctx.adapter) == entries
  end

  test "the Backlog is told of a comment marked, and of nothing else", ctx do
    {ticket, comment} = posting(ctx)
    workspace_id = ctx.scope.workspace.id
    Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(workspace_id))
    ticket_id = ticket.public_id

    ctx |> send_report(report(comment.comment_id)) |> no_content!()
    assert_receive {:tickets_changed, [^ticket_id]}

    ctx |> send_report(report(comment.comment_id, "unreachable", 1)) |> no_content!()
    refute_receive {:tickets_changed, _ids}, 100
  end

  test "an open page of the ticket's work item is read again after a report", ctx do
    {_ticket, work_item, comment} = taken_in(ctx)
    view = ticket_tab(ctx, work_item)
    assert render(view) =~ "Start with the basket."

    rewrite(comment, "Start with the payment form.")
    refute render(view) =~ "Start with the payment form."

    ctx |> send_report(report(comment.comment_id)) |> no_content!()
    assert Repo.get!(Comment, comment.id).post_state == :not_posted
    assert render(view) =~ "Start with the payment form."
  end

  test "an open page of the ticket's work item is read again after an echo", ctx do
    {ticket, work_item, comment} = taken_in(ctx)
    view = ticket_tab(ctx, work_item)
    assert render(view) =~ "Start with the basket."

    rewrite(comment, "Start with the payment form.")
    refute render(view) =~ "Start with the payment form."

    echo(ctx, ticket, comment, "C-32")
    assert Repo.get!(Comment, comment.id).post_state == :posted
    assert render(view) =~ "Start with the payment form."
  end

  test "a comment's way: taken in, not posted, posted again, then echoed as posted", ctx do
    {ticket, comment} = posting(ctx)
    id = comment.comment_id

    entry = %{
      "comment_id" => id,
      "ref" => ticket.external_ref,
      "author_name" => comment.author_name,
      "body" => "Start with the basket."
    }

    assert [%{kind: "work_item"}, %{kind: "comment", data: ^entry}] = Feed.entries(ctx.adapter)

    # The adapter cannot reach the source.
    ctx |> send_report(report(id, "unreachable")) |> no_content!()

    assert %Comment{post_state: :not_posted, post_failure: :unreachable} =
             Repo.get!(Comment, comment.id)

    # A member posts it again: a second entry, the same comment_id.
    assert {:ok, %Comment{post_state: :posting, post_failure: nil}} =
             Sources.post_again(ctx.scope, id)

    assert [_work_item, %{data: ^entry}, %{kind: "comment", data: ^entry}] =
             Feed.entries(ctx.adapter)

    # The adapter posts it and sends it back with its comment_id.
    url = "https://tracker.example.com/comments/C-31"

    body = %{
      "version" => 1,
      "time" => now_time(),
      "item_ref" => ticket.external_ref,
      "comments" => [
        %{
          "ref" => "C-31",
          "url" => url,
          "comment_id" => id,
          "author" => %{"name" => "Example integration", "kind" => "automation"},
          "body" => "#{comment.author_name} wrote in Qory Apiary:\n\nStart with the basket.",
          "body_format" => "markdown",
          "created_at" => "2026-11-06T10:00:00Z",
          "updated_at" => "2026-11-06T10:00:00Z"
        }
      ]
    }

    conn =
      signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
        target: "/v1/source-items/comments",
        content_type: "application/json",
        delivery: nil
      )

    no_content!(conn)

    assert [%Comment{} = posted] = Repo.all(from c in Comment, where: c.item_id == ^ticket.id)
    assert posted.id == comment.id
    assert {posted.post_state, posted.post_failure} == {:posted, nil}
    assert {posted.external_ref, posted.url} == {"C-31", url}
    assert posted.body == "Start with the basket."
    assert posted.author_name == comment.author_name
    assert posted.source_updated_at == ~U[2026-11-06 10:00:00Z]

    # A late report of the first entry changes nothing.
    ctx |> send_report(report(id, "unreachable", 1)) |> no_content!()
    assert Repo.get!(Comment, comment.id).post_state == :posted
  end
end

defmodule Apiary.Sources.MemberCommentTest do
  # A member's comment on a ticket in `source_item_comments` (`Apiary.Sources.Comment`):
  # the database checks on it beside the comments the adapter sends, its changeset,
  # and the name it has for its author.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.Sources.Comment

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, ticket: backlog_ticket_fixture(scope)}
  end

  defp at, do: DateTime.utc_now(:second)
  defp id, do: Apiary.PublicId.generate("sc")

  defp source(ctx, fields \\ %{}) do
    Map.merge(
      %{
        organisation_id: ctx.scope.organisation.id,
        item_id: ctx.ticket.id,
        external_ref: "c-#{System.unique_integer([:positive])}",
        url: "https://forge.example.com/acme/shop/issues/12#c",
        author_name: "Robin Example",
        author_kind: :person,
        body: "A comment.",
        body_format: "markdown",
        source_created_at: at(),
        source_updated_at: at()
      },
      fields
    )
  end

  defp member(ctx, fields) do
    source(
      ctx,
      Map.merge(
        %{
          external_ref: nil,
          url: nil,
          author_id: ctx.scope.user.id,
          comment_id: id(),
          post_state: :posting
        },
        fields
      )
    )
  end

  # The insert's result: `:ok`, or the name of the constraint the database refused it by.
  # Each runs in a savepoint, so a refusal leaves the test's transaction usable.
  defp insert(fields) do
    Repo.transaction(fn -> Repo.insert!(struct(Comment, fields)) end)
    :ok
  rescue
    error in Ecto.ConstraintError -> error.constraint
    error in Postgrex.Error -> error.postgres.constraint
  end

  # An insert in SQL, with a state and a failure no `Ecto.Enum` would take.
  defp raw_insert(ctx, state, failure) do
    Repo.transaction(fn ->
      Repo.query!(
        "INSERT INTO source_item_comments (id, organisation_id, item_id, author_name, " <>
          "author_kind, body, body_format, source_created_at, source_updated_at, " <>
          "comment_id, post_state, post_failure, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1, $2, 'Dana', 'person', 'Hi.', 'markdown', now(), " <>
          "now(), $3, $4, $5, now(), now())",
        [
          Ecto.UUID.dump!(ctx.scope.organisation.id),
          Ecto.UUID.dump!(ctx.ticket.id),
          id(),
          state,
          failure
        ]
      )
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres.constraint
  end

  describe "the database" do
    test "takes a source's comment as before, and a member's comment in each state", ctx do
      assert insert(source(ctx)) == :ok
      assert insert(member(ctx, %{})) == :ok
      assert insert(member(ctx, %{post_state: :kept})) == :ok

      assert insert(
               member(ctx, %{
                 post_state: :posted,
                 external_ref: "posted-1",
                 url: "https://forge.example.com/acme/shop/issues/12#posted-1"
               })
             ) == :ok

      for failure <- [:item_gone, :not_permitted, :too_long, :unreachable, :deleted_at_source] do
        assert insert(member(ctx, %{post_state: :not_posted, post_failure: failure})) == :ok
      end

      # A member's comment whose account's row is gone.
      assert insert(member(ctx, %{author_id: nil})) == :ok
    end

    test "refuses an id outside its shape, and an id twice", ctx do
      for bad <- ["cm_0123456789abcdef", "sc_0123456789ABCDEF", "sc_0123456789abcdeu", "sc_"] do
        assert insert(member(ctx, %{comment_id: bad})) == "source_item_comments_comment_id_check",
               bad
      end

      taken = id()
      assert insert(member(ctx, %{comment_id: taken})) == :ok

      assert insert(member(ctx, %{comment_id: taken})) ==
               "source_item_comments_comment_id_index"
    end

    test "refuses a source's comment with a state, a member or no ref", ctx do
      check = "source_item_comments_post_state_check"

      assert insert(source(ctx, %{post_state: :posting})) == check
      assert insert(source(ctx, %{author_id: ctx.scope.user.id})) == check
      assert insert(source(ctx, %{external_ref: nil, url: nil})) == check
      assert insert(member(ctx, %{post_state: nil})) == check
    end

    test "has a ref and a URL exactly when a member's comment is posted", ctx do
      check = "source_item_comments_post_state_check"
      ref = %{external_ref: "r1", url: "https://forge.example.com/acme/shop/issues/12#r1"}

      assert insert(member(ctx, %{post_state: :posted})) == check

      for state <- [:posting, :kept] do
        assert insert(member(ctx, Map.put(ref, :post_state, state))) == check, inspect(state)
      end

      assert insert(
               member(
                 ctx,
                 Map.merge(ref, %{post_state: :not_posted, post_failure: :unreachable})
               )
             ) == check

      assert insert(member(ctx, %{post_state: :posted, external_ref: "r2"})) ==
               "source_item_comments_ref_url_check"

      assert insert(source(ctx, %{url: nil})) == "source_item_comments_ref_url_check"
    end

    test "has a failure exactly when a member's comment is not posted", ctx do
      check = "source_item_comments_post_failure_check"

      assert insert(member(ctx, %{post_state: :not_posted})) == check
      assert insert(member(ctx, %{post_failure: :too_long})) == check
      assert insert(member(ctx, %{post_state: :kept, post_failure: :item_gone})) == check
      assert insert(source(ctx, %{post_failure: :unreachable})) == check
    end

    test "refuses a state or a failure outside its list", ctx do
      assert raw_insert(ctx, "sent", nil) == "source_item_comments_post_state_check"
      assert raw_insert(ctx, "not_posted", "lost") == "source_item_comments_post_failure_check"
      assert raw_insert(ctx, "not_posted", "too_long") == :ok
    end

    test "refuses an author no account has", ctx do
      assert insert(member(ctx, %{author_id: Ecto.UUID.generate()})) ==
               "source_item_comments_author_id_fkey"
    end
  end

  describe "member_changeset/3" do
    defp changeset(attrs),
      do: Comment.member_changeset(%Comment{}, attrs, DateTime.utc_now())

    test "makes a member's comment, posting or kept, in Markdown, at its time" do
      now = ~U[2026-11-06 10:00:00.123456Z]

      changeset =
        Comment.member_changeset(
          %Comment{},
          %{body: "Hi.", author_name: "dana", post_state: :kept},
          now
        )

      assert changeset.valid?
      comment = Ecto.Changeset.apply_changes(changeset)
      assert Apiary.PublicId.valid?("sc", comment.comment_id)
      assert {comment.author_kind, comment.body_format} == {:person, "markdown"}
      assert comment.source_created_at == ~U[2026-11-06 10:00:00Z]
      assert comment.source_updated_at == ~U[2026-11-06 10:00:00Z]
      assert {comment.external_ref, comment.url, comment.post_state} == {nil, nil, :kept}
    end

    test "refuses an empty body, one past 65,000 characters, a name past 100, and another state" do
      base = %{body: "Hi.", author_name: "dana", post_state: :posting}

      for {attrs, field} <- [
            {%{body: ""}, :body},
            {%{body: String.duplicate("é", 65_001)}, :body},
            {%{author_name: String.duplicate("é", 101)}, :author_name},
            {%{author_name: ""}, :author_name},
            {%{post_state: :posted}, :post_state},
            {%{post_state: :sent}, :post_state}
          ] do
        changeset = changeset(Map.merge(base, attrs))
        refute changeset.valid?, inspect(attrs)
        assert Keyword.has_key?(changeset.errors, field), inspect(attrs)
      end

      assert changeset(Map.put(base, :body, String.duplicate("é", 65_000))).valid?
    end
  end

  describe "first_state/1" do
    test "is posting only for a source whose description sets comments: true" do
      assert Comment.first_state(true) == :posting
      assert Comment.first_state(false) == :kept
      assert Comment.first_state(nil) == :kept
    end
  end

  describe "member_name/1" do
    test "is the short name without the characters a line refuses, cut to 100, else Member" do
      assert Comment.member_name("dana@example.com") == "dana"

      # The control characters, C1 among them, the separators, the bidirectional controls
      # and the format characters a prose line refuses.
      for c <-
            ~w(0000 0009 000A 001F 007F 0085 009F 00AD 061C 180E 200B 200E 200F 2028 2029 202A 202E 2060 2064 2066 2069 FEFF FFF9 FFFB) do
        char = <<String.to_integer(c, 16)::utf8>>
        assert Comment.member_name("da" <> char <> "na@example.com") == "dana", c
      end

      # Other characters stay: a join control, and spaces beside other characters.
      assert Comment.member_name("da\u200Dna\u3000x@example.com") == "da\u200Dna\u3000x"

      assert Comment.member_name(String.duplicate("é", 150) <> "@example.com") ==
               String.duplicate("é", 100)

      for blank <- [
            "\n\t@example.com",
            "\t @example.com",
            "\u3000@example.com",
            "\u00A0\u1680\u2000\u200A\u202F\u205F@example.com",
            "@example.com"
          ] do
        assert Comment.member_name(blank) == "Member", inspect(blank)
      end

      assert Comment.member_name(nil) == "Member"
      assert Comment.member_name(<<0xFF>>) == "Member"
    end
  end
end

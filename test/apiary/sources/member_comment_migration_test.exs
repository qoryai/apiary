defmodule Apiary.Sources.MemberCommentMigrationTest do
  # The migrations that keep a member's comment on a ticket in `source_item_comments`:
  # the columns and checks, then their validation, run down and up again inside the
  # test's transaction, which rolls it all back; and the indexes, made concurrently,
  # which no transaction can run, read as the migrated database has them. They change
  # `source_item_comments` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}

  @keep {20_261_106_130_000, Apiary.Repo.Migrations.KeepAMemberSCommentOnATicket,
         "keep_a_member_s_comment_on_a_ticket"}
  @validate {20_261_106_130_100, Apiary.Repo.Migrations.ValidateAMemberSCommentOnATicket,
             "validate_a_member_s_comment_on_a_ticket"}
  @index {20_261_106_130_200, Apiary.Repo.Migrations.IndexAMemberSCommentOnATicket,
          "index_a_member_s_comment_on_a_ticket"}

  @columns ~w(author_id comment_id post_failure post_state)
  @constraints ~w(
    source_item_comments_author_id_fkey
    source_item_comments_comment_id_check
    source_item_comments_post_failure_check
    source_item_comments_post_state_check
    source_item_comments_ref_url_check
  )

  setup_all do
    for {version, migration, name} <- [@keep, @validate, @index],
        not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp columns,
    do:
      rows(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'source_item_comments' AND column_name = ANY($1) " <>
          "ORDER BY column_name",
        [@columns]
      )
      |> List.flatten()

  defp nullable(column),
    do:
      rows(
        "SELECT is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'source_item_comments' AND column_name = $1",
        [column]
      ) == [["YES"]]

  # Each of the constraints there is, with whether it is validated.
  defp constraints,
    do:
      rows(
        "SELECT conname, convalidated FROM pg_constraint WHERE conname = ANY($1) " <>
          "ORDER BY conname",
        [@constraints]
      )

  @source_columns "id, external_ref, url, author_name, author_kind, body, body_format, " <>
                    "truncated, source_created_at, source_updated_at, deleted_at, " <>
                    "deleted_by_complete_at, inserted_at, updated_at"

  defp source_rows,
    do:
      rows(
        "SELECT #{@source_columns} FROM source_item_comments WHERE external_ref LIKE 'src-%' " <>
          "ORDER BY external_ref"
      )

  defp source_comment!(scope, ticket, ref) do
    at = DateTime.utc_now(:second)

    Repo.insert!(%Apiary.Sources.Comment{
      organisation_id: scope.organisation.id,
      item_id: ticket.id,
      external_ref: ref,
      url: "https://forge.example.com/acme/shop/issues/12#" <> ref,
      author_name: "Robin Example",
      author_kind: :automation,
      body: "Comment #{ref}.",
      body_format: "markdown",
      truncated: ["body"],
      source_created_at: at,
      source_updated_at: at,
      deleted_at: if(ref == "src-2", do: DateTime.utc_now())
    })
  end

  test "down drops the columns and checks and deletes unposted member comments; up adds them back, the rows there unchanged" do
    %{scope: scope} = sign_up_fixture()
    ticket = backlog_ticket_fixture(scope)
    source_comment!(scope, ticket, "src-1")
    source_comment!(scope, ticket, "src-2")
    before = source_rows()
    assert length(before) == 2

    {:ok, _work_item} = WorkItems.take_in(scope, ticket.public_id, %{comment: "Hi."})

    Repo.query!(
      "UPDATE source_item_comments SET post_state = 'posted', external_ref = 'posted-1', " <>
        "url = 'https://forge.example.com/acme/shop/issues/12#posted-1' " <>
        "WHERE body = 'Hi.'"
    )

    {:ok, _other} =
      WorkItems.take_in(scope, backlog_ticket_fixture(scope).public_id, %{comment: "Unposted."})

    assert columns() == @columns
    assert constraints() == Enum.map(@constraints, &[&1, true])
    assert nullable("external_ref") and nullable("url")

    down!(@validate)
    assert constraints() == Enum.map(@constraints, &[&1, true])
    down!(@keep)

    assert columns() == []
    assert constraints() == []
    refute nullable("external_ref") or nullable("url")
    assert source_rows() == before
    # The member's comment that was posted stays as a comment of its source; the one
    # that was not is gone.
    assert rows("SELECT body FROM source_item_comments WHERE body IN ('Hi.', 'Unposted.')") ==
             [["Hi."]]

    up!(@keep)
    assert constraints() == Enum.map(@constraints, &[&1, false])
    assert columns() == @columns
    assert nullable("external_ref") and nullable("url")

    up!(@validate)
    assert constraints() == Enum.map(@constraints, &[&1, true])
    assert source_rows() == before

    assert rows(
             "SELECT count(*) FROM source_item_comments WHERE author_id IS NOT NULL OR " <>
               "comment_id IS NOT NULL OR post_state IS NOT NULL OR post_failure IS NOT NULL"
           ) == [[0]]

    # The table works as before, and takes a member's comment again.
    assert {:ok, _work_item} =
             WorkItems.take_in(scope, backlog_ticket_fixture(scope).public_id, %{
               comment: "Again."
             })
  end

  test "the indexes are made concurrently, outside a transaction, of the rows that have the column" do
    {_version, migration, _name} = @index
    assert migration.__migration__()[:disable_ddl_transaction] == true
    assert migration.__migration__()[:disable_migration_lock] == true

    assert rows(
             "SELECT indexname, indexdef FROM pg_indexes " <>
               "WHERE tablename = 'source_item_comments' AND indexname = ANY($1) " <>
               "ORDER BY indexname",
             [
               ~w(source_item_comments_author_id_index source_item_comments_comment_id_index)
             ]
           ) == [
             [
               "source_item_comments_author_id_index",
               "CREATE INDEX source_item_comments_author_id_index ON public.source_item_comments " <>
                 "USING btree (author_id) WHERE (author_id IS NOT NULL)"
             ],
             [
               "source_item_comments_comment_id_index",
               "CREATE UNIQUE INDEX source_item_comments_comment_id_index ON " <>
                 "public.source_item_comments USING btree (comment_id) " <>
                 "WHERE (comment_id IS NOT NULL)"
             ]
           ]
  end

  test "the key to the author's account empties when the account's row goes" do
    assert [[definition]] =
             rows(
               "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
                 "WHERE conname = 'source_item_comments_author_id_fkey'"
             )

    assert definition == "FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE SET NULL"
  end
end

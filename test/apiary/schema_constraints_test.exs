defmodule Apiary.SchemaConstraintsTest do
  # The database's rules of the core's tables, asked in raw SQL so that no changeset
  # stands between the write and the database. They hold under every edition, so this
  # file asks nothing of one, and runs against the core's migrations alone as well.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  # Sets `assignments` on the row `id` of `table`, with `params` after the id: $2 onwards.
  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  test "the database refuses a level other than owner, admin or member" do
    %{membership: membership} = sign_up_fixture()

    assert %{num_rows: 1} =
             Repo.query!("UPDATE memberships SET level = 'admin' WHERE id = $1", [
               Ecto.UUID.dump!(membership.id)
             ])

    assert_raise Postgrex.Error, ~r/memberships_level_check/, fn ->
      Repo.query!("UPDATE memberships SET level = 'root' WHERE id = $1", [
        Ecto.UUID.dump!(membership.id)
      ])
    end
  end

  test "the user references are indexed" do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname FROM pg_indexes
      WHERE indexname IN ('invitations_invited_by_id_index', 'access_keys_created_by_id_index')
      """)

    assert length(rows) == 2
  end

  test "an organisation's slug keeps to the rules of a slug, forty characters at most" do
    %{organisation: %{id: id}} = sign_up_fixture()

    assert %{num_rows: 1} =
             update!("organisations", id, "slug = $2", [
               "acme-2-#{System.unique_integer([:positive])}"
             ])

    for slug <- [
          "",
          "Acme",
          "-acme",
          "acme-",
          "acme_labs",
          "acme labs",
          String.duplicate("a", 41)
        ] do
      refused("organisations_slug_format", fn ->
        update!("organisations", id, "slug = $2", [slug])
      end)
    end
  end

  test "an organisation's deletion marks go together, and an asker with an erasure" do
    %{organisation: %{id: id}, user: user} = sign_up_fixture()
    asker = Ecto.UUID.dump!(user.id)

    for assignments <- [
          "deletion_marked_at = now()",
          "purge_after = now()",
          "purge_trigger = 'grace_period'",
          "deletion_marked_at = now(), purge_after = now()",
          "purge_started_at = now()"
        ] do
      refused("organisations_deletion_mark_check", fn ->
        update!("organisations", id, assignments)
      end)
    end

    refused("organisations_deletion_mark_check", fn ->
      update!(
        "organisations",
        id,
        "deletion_marked_at = now(), purge_after = now(), purge_trigger = 'grace_period', " <>
          "purge_requested_by_id = $2",
        [asker]
      )
    end)

    assert %{num_rows: 1} =
             update!(
               "organisations",
               id,
               "deletion_marked_at = now(), purge_after = now(), " <>
                 "purge_trigger = 'erasure_request', purge_requested_by_id = $2, " <>
                 "purge_started_at = now()",
               [asker]
             )
  end

  test "an organisation is purged for a grace period or an erasure request alone" do
    %{organisation: %{id: id}} = sign_up_fixture()

    refused("organisations_purge_trigger_check", fn ->
      update!(
        "organisations",
        id,
        "deletion_marked_at = now(), purge_after = now(), purge_trigger = 'whim'"
      )
    end)
  end

  test "a membership's suspender only with a suspension" do
    %{membership: membership, user: user} = sign_up_fixture()
    suspender = Ecto.UUID.dump!(user.id)

    refused("memberships_suspension_check", fn ->
      update!("memberships", membership.id, "suspended_by_id = $2", [suspender])
    end)

    assert %{num_rows: 1} =
             update!("memberships", membership.id, "suspended_at = now(), suspended_by_id = $2", [
               suspender
             ])
  end

  test "an account has an email address until it is deleted" do
    %{user: user} = sign_up_fixture()

    refused("users_email_unless_deleted", fn -> update!("users", user.id, "email = NULL") end)

    assert %{num_rows: 1} = update!("users", user.id, "email = NULL, deleted_at = now()")
  end

  test "the instance's settings are one row at most" do
    # Whether or not the instance has its row yet, a second has no key left to take.
    Repo.query!(
      "INSERT INTO instance_settings (updated_at) VALUES (now()) ON CONFLICT DO NOTHING"
    )

    refused("instance_settings_pkey", fn ->
      Repo.query!("INSERT INTO instance_settings (updated_at) VALUES (now())")
    end)

    refused("instance_settings_one_row_check", fn ->
      Repo.query!("INSERT INTO instance_settings (id, updated_at) VALUES (false, now())")
    end)
  end

  test "a node's kind never changes, and holds its public id's prefix and its limit" do
    %{scope: scope} = sign_up_fixture()
    node = node_fixture(scope)
    pool = pool_fixture(scope)

    # Whatever writes it, the kind stays the one the node was made with.
    refused("kind is fixed", fn ->
      update!(
        "nodes",
        node.id,
        "kind = 'pool', public_id = 'np_' || substr(public_id, 4), instance_limit = NULL"
      )
    end)

    # A kind that is none breaks every check that names the kinds.
    refused("nodes_(kind|instance_limit|public_id)_check", fn ->
      Repo.query!(
        """
        INSERT INTO nodes (id, organisation_id, workspace_id, public_id, name, kind,
          instance_limit, inserted_at, updated_at)
        SELECT gen_random_uuid(), organisation_id, workspace_id, 'nd_0000000000000000',
          'build-02', 'machine', 1, now(), now()
        FROM nodes WHERE id = $1
        """,
        [Ecto.UUID.dump!(node.id)]
      )
    end)

    refused("nodes_public_id_check", fn ->
      update!("nodes", node.id, "public_id = 'np_' || substr(public_id, 4)")
    end)

    refused("nodes_public_id_check", fn -> update!("nodes", node.id, "public_id = 'nd_ABC'") end)

    refused("nodes_instance_limit_check", fn ->
      update!("nodes", node.id, "instance_limit = 2")
    end)

    refused("nodes_instance_limit_check", fn ->
      update!("nodes", node.id, "instance_limit = NULL")
    end)

    refused("nodes_instance_limit_check", fn ->
      update!("nodes", pool.id, "instance_limit = 0")
    end)

    refused("nodes_instance_limit_check", fn ->
      update!("nodes", pool.id, "instance_limit = 10001")
    end)

    refused("nodes_name_check", fn -> update!("nodes", pool.id, "name = ''") end)

    refused("nodes_deletion_check", fn ->
      update!("nodes", pool.id, "deleted_by_id = created_by_id")
    end)

    assert %{num_rows: 1} = update!("nodes", pool.id, "instance_limit = 10000")
    assert %{num_rows: 1} = update!("nodes", pool.id, "instance_limit = NULL")
    assert %{num_rows: 1} = update!("nodes", pool.id, "kind = 'pool', name = 'spot-runners'")
  end
end

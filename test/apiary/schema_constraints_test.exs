defmodule Apiary.SchemaConstraintsTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  test "H5: the database refuses a level other than owner or member" do
    %{membership: membership} = sign_up_fixture()

    assert_raise Postgrex.Error, ~r/memberships_level_check/, fn ->
      Repo.query!("UPDATE memberships SET level = 'admin' WHERE id = $1", [
        Ecto.UUID.dump!(membership.id)
      ])
    end
  end

  test "H5: and the same for an invitation" do
    %{scope: scope} = sign_up_fixture()
    %{invitation: invitation} = invitation_fixture(scope)

    assert_raise Postgrex.Error, ~r/invitations_level_check/, fn ->
      Repo.query!("UPDATE invitations SET level = 'root' WHERE id = $1", [
        Ecto.UUID.dump!(invitation.id)
      ])
    end
  end

  test "H5: the user references are indexed" do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname FROM pg_indexes
      WHERE indexname IN ('invitations_invited_by_id_index', 'access_keys_created_by_id_index')
      """)

    assert length(rows) == 2
  end
end

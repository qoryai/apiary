defmodule Apiary.LockRowsTest do
  @moduledoc """
  Where the core asks the edition to lock its own rows for a change
  (`c:Apiary.Edition.lock_rows/1`): once at each point a change has, before its first
  write, recorded by a stub that answers as the configured edition
  (`Apiary.EditionStubs.RecordsLockRows`). The core's own answer is `:ok`, and locks
  nothing.
  """
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Membership

  # The points asked since the last call, in order.
  defp points(acc \\ []) do
    receive do
      {:lock_rows, point} -> points([point | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp recording do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.RecordsLockRows)
    points()
  end

  defp url(token), do: "http://localhost/invitations/#{token}"

  test "the core's answer is :ok, and it holds no lock" do
    %{scope: scope, organisation: organisation, user: user} = sign_up_fixture()

    Repo.transact(fn ->
      held = fn ->
        Repo.query!("SELECT count(*) FROM pg_locks WHERE pid = pg_backend_pid()").rows
      end

      before = held.()

      for about <- [{:places, scope}, {:people, scope, organisation}, {:account, user.id}] do
        assert Apiary.Edition.Core.lock_rows(about) == :ok
      end

      assert held.() == before
      {:ok, nil}
    end)
  end

  describe "a change of the organisation's people asks {:places}, then {:people}, once each" do
    setup do
      %{scope: owner} = sign_up_fixture()
      %{membership: member, scope: member_scope} = member_fixture(owner, :member)
      %{owner: owner, member: member, member_scope: member_scope}
    end

    test "a change of level", %{owner: owner, member: member} do
      recording()

      assert {:ok, %Membership{level: :admin}} =
               Organisations.set_member_level(owner, member.id, :admin)

      assert points() == [:places, :people]
    end

    test "a removal, and leaving", %{owner: owner, member: member} do
      %{membership: leaving, scope: leaving_scope} = member_fixture(owner, :member)
      recording()

      assert {:ok, _removed} = Organisations.remove_member(owner, member.id)
      assert points() == [:places, :people]

      assert {:ok, _left} = Organisations.remove_member(leaving_scope, leaving.id)
      assert points() == [:places, :people]
    end

    test "a suspension, and an activation", %{owner: owner, member: member} do
      recording()

      assert {:ok, %Membership{}} = Organisations.suspend_member(owner, member.id)
      assert points() == [:places, :people]

      assert {:ok, %Membership{suspended_at: nil}} =
               Organisations.activate_member(owner, member.id)

      assert points() == [:places, :people]
    end
  end

  describe "joining asks {:people} once, once the organisation is held" do
    test "an invitation's acceptance" do
      %{scope: owner} = sign_up_fixture()
      user = user_fixture()
      %{token: token} = invitation_fixture(owner, %{"email" => user.email})
      recording()

      assert {:ok, %Membership{}} = Organisations.accept_invitation(user, token)
      assert points() == [:people]
    end

    test "a sign-up with an invitation" do
      %{scope: owner} = sign_up_fixture()
      email = unique_user_email()
      %{token: token} = invitation_fixture(owner, %{"email" => email})
      recording()

      assert {:ok, _signed_up} =
               Organisations.sign_up_user(valid_user_attributes(%{email: email}), token)

      assert points() == [:people]
    end

    test "an invitation, which writes no membership, asks none" do
      %{scope: owner} = sign_up_fixture()
      recording()

      assert {:ok, _invitation} =
               Organisations.invite_member(owner, %{"email" => "invitee@example.com"}, &url/1)

      assert points() == []
    end
  end

  test "an account's deletion asks {:account} once, for every organisation it is in" do
    %{scope: owner} = sign_up_fixture()
    %{scope: elsewhere} = sign_up_fixture()
    %{user: user} = member_fixture(owner, :admin)
    join_fixture(elsewhere, user)
    recording()

    assert {:ok, _deleted} = Accounts.delete_user(%Scope{user: user})
    assert points() == [:account]
  end
end

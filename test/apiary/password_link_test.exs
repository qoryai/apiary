defmodule Apiary.PasswordLinkTest do
  @moduledoc """
  Password links (`Apiary.Accounts.build_password_link/3`, `set_password_by_link/2`): a
  one-time link that sets an account's password, which an instance admin makes while the
  instance sends no mail, for 24 hours, and the instance, a release command, makes mail or
  not, for an hour. Only the token's hash is stored; it works once, one per account at a
  time, and setting the password ends every session of the account. Each link is an
  `account.password_link` entry in the instance's organisation's trail.
  """
  # Not async: an instance admin is an owner of the suite's instance organisation, which
  # every test shares, and each link writes to its trail.
  use Apiary.DataCase, async: false

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Organisations}
  alias Apiary.Accounts.{Scope, User, UserToken}
  alias Apiary.Audit.Entry

  @password "a long pass phrase"

  # The fixtures sign people up and in with mail, as the suite's instance has it; a test
  # then turns it off for its own process.
  defp with_mail(fun) do
    source = Apiary.Mail.source()
    Apiary.Mail.put_test_source(:env)

    try do
      fun.()
    after
      Apiary.Mail.put_test_source(source)
    end
  end

  defp account, do: with_mail(&user_fixture/0)

  defp instance_admin do
    %{user: user} = with_mail(&sign_up_fixture/0)
    {:ok, _} = Organisations.grant_instance_admin(user)
    Scope.for_user(user)
  end

  defp url_fun(token), do: "https://qory.example.com/users/password/#{token}"

  defp token_of(url) do
    [_, token] = Regex.run(~r{/users/password/([A-Za-z0-9_-]+)$}, url)
    token
  end

  defp make(by, user) do
    assert {:ok, url, %DateTime{} = expires_at} =
             Accounts.build_password_link(by, user, &url_fun/1)

    {token_of(url), expires_at}
  end

  defp password_tokens(user),
    do:
      Repo.all(
        from t in UserToken,
          where: t.user_id == ^user.id and t.context in ["password", "password:release"]
      )

  defp entries(action \\ "account.password_link"),
    do: Repo.all(from e in Entry, where: e.action == ^action, order_by: [asc: e.inserted_at])

  defp backdate(user, minutes) do
    at = DateTime.add(DateTime.utc_now(:second), -minutes * 60, :second)

    Repo.update_all(
      from(t in UserToken, where: t.user_id == ^user.id and like(t.context, "password%")),
      set: [inserted_at: at]
    )
  end

  defp set(token, password \\ @password),
    do:
      Accounts.set_password_by_link(token, %{
        "password" => password,
        "password_confirmation" => password
      })

  describe "build_password_link/3 by an instance admin" do
    setup do
      Apiary.Mail.put_test_source(:none)
      %{admin: instance_admin()}
    end

    test "without mail, makes a link for 24 hours; only its hash is stored", %{admin: admin} do
      user = account()
      before = DateTime.utc_now(:second)

      {token, expires_at} = make(admin, user)

      assert DateTime.diff(expires_at, before, :hour) in 23..24
      assert [stored] = password_tokens(user)
      assert stored.context == "password"
      assert stored.sent_to == user.email
      assert stored.token == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
      refute stored.token =~ token
      assert byte_size(Base.url_decode64!(token, padding: false)) == 32

      assert %User{id: id} = Accounts.get_user_by_password_link(token)
      assert id == user.id
    end

    test "is an account.password_link entry in the instance's trail, by the admin, without the link",
         %{admin: admin} do
      # An account with no membership of the instance's organisation: about the organisation.
      user = account()
      {token, _} = make(admin, user)

      assert [entry] = entries()
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}
      assert entry.details["user_id"] == user.id
      refute inspect(entry) =~ token
      refute inspect(entry) =~ user.email

      # A member of it: about their membership.
      %{user: member} = with_mail(&sign_up_fixture/0)
      {:ok, %{membership: membership}} = Organisations.grant_instance_admin(member)
      make(admin, member)

      assert [_, entry] = entries()
      assert {entry.subject_kind, entry.subject_id} == {"membership", membership.id}
    end

    test "a new link ends the one before", %{admin: admin} do
      user = account()
      {first, _} = make(admin, user)
      {second, _} = make(admin, user)

      assert [_one] = password_tokens(user)
      refute Accounts.get_user_by_password_link(first)
      assert Accounts.get_user_by_password_link(second)
      assert {:error, :invalid} = set(first)
    end

    test "changes nothing else: the password and the sessions stay until it is used",
         %{admin: admin} do
      user = account() |> set_password()
      session = Accounts.generate_user_session_token(user)

      make(admin, user)

      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_session_token(session)
    end

    test "with mail, is refused, and nothing is made" do
      admin = instance_admin()
      user = account()
      Apiary.Mail.put_test_source(:env)

      assert {:error, :mail_set} = Accounts.build_password_link(admin, user, &url_fun/1)
      assert password_tokens(user) == []
      assert entries() == []
    end

    test "for their own account, is refused, and nothing is made", %{admin: admin} do
      assert {:error, :own_account} =
               Accounts.build_password_link(admin, admin.user, &url_fun/1)

      assert password_tokens(admin.user) == []
      assert entries() == []
    end

    test "for a deleted account, is refused", %{admin: admin} do
      user = account()
      {:ok, _} = Accounts.delete_user(%Scope{user: user})

      assert {:error, :not_found} = Accounts.build_password_link(admin, user, &url_fun/1)
      assert entries() == []
    end
  end

  describe "build_password_link/3 by anyone else" do
    test "an owner of another organisation, a member of the instance's, no one: refused" do
      user = account()
      %{scope: owner} = with_mail(&sign_up_fixture/0)
      admin = instance_admin()
      %{scope: member} = with_mail(fn -> member_fixture(in_instance(admin)) end)
      Apiary.Mail.put_test_source(:none)

      for scope <- [owner, member, %Scope{}, %Scope{access_key: %Apiary.AccessKeys.AccessKey{}}] do
        assert {:error, :forbidden} = Accounts.build_password_link(scope, user, &url_fun/1)
      end

      assert password_tokens(user) == []
      assert entries() == []
    end

    test "an instance admin no more: refused" do
      admin = instance_admin()
      user = account()
      {:ok, _} = Organisations.revoke_instance_admin(admin.user)
      Apiary.Mail.put_test_source(:none)

      assert {:error, :forbidden} = Accounts.build_password_link(admin, user, &url_fun/1)
      assert password_tokens(user) == []
    end
  end

  # A person's scope in the instance's organisation, at its workspace Main.
  defp in_instance(%Scope{user: user}) do
    instance =
      Repo.get!(Apiary.Organisations.Organisation, Apiary.Edition.instance_organisation_id())

    [workspace | _] = Organisations.list_workspaces(Scope.for_instance(instance))
    workspace_scope(user, workspace)
  end

  describe "build_password_link/3 by the instance, a release command" do
    test "makes a link for an hour, mail or not, by the instance from the scope's origin" do
      for source <- [:none, :env] do
        Apiary.Mail.put_test_source(source)
        user = account()
        before = DateTime.utc_now(:second)

        by =
          nil
          |> Scope.for_instance()
          |> Scope.put_origin(%{worker: "Apiary.Release.password_link/1"})

        {token, expires_at} = make(by, user)

        assert DateTime.diff(expires_at, before, :minute) in 59..60
        assert [%UserToken{context: "password:release"}] = password_tokens(user)
        assert Accounts.get_user_by_password_link(token)

        entry = List.last(entries())
        assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
        assert entry.worker == "Apiary.Release.password_link/1"
        assert entry.details["user_id"] == user.id
      end
    end
  end

  describe "set_password_by_link/2" do
    setup do
      Apiary.Mail.put_test_source(:none)
      %{admin: instance_admin(), user: account()}
    end

    test "sets the password, uses the link up and ends every session", %{admin: admin, user: user} do
      session = Accounts.generate_user_session_token(user)
      {token, _} = make(admin, user)

      assert {:ok, {%User{id: id}, ended}} = set(token)
      assert id == user.id
      assert Enum.any?(ended, &(&1.context == "session" and &1.token == session))

      assert %User{} = Accounts.get_user_by_email_and_password(user.email, @password)
      refute Accounts.get_user_by_session_token(session)
      assert password_tokens(user) == []

      # Once.
      refute Accounts.get_user_by_password_link(token)
      assert {:error, :invalid} = set(token, "another pass phrase")
      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "a password refused is the form's error, and the link still works",
         %{admin: admin, user: user} do
      {token, _} = make(admin, user)

      assert {:error, %Ecto.Changeset{} = changeset} = set(token, "short")
      assert "should be at least 12 character(s)" in errors_on(changeset).password

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.set_password_by_link(token, %{
                 "password" => @password,
                 "password_confirmation" => "something else entirely"
               })

      assert "does not match password" in errors_on(changeset).password_confirmation
      assert Accounts.get_user_by_password_link(token)
      assert {:ok, _} = set(token)
    end

    test "an admin's link works for 24 hours, a release command's for one",
         %{admin: admin, user: user} do
      {token, _} = make(admin, user)
      backdate(user, 24 * 60 - 1)
      assert Accounts.get_user_by_password_link(token)
      backdate(user, 24 * 60 + 1)
      refute Accounts.get_user_by_password_link(token)
      assert {:error, :invalid} = set(token)

      {token, _} = make(Scope.for_instance(nil), user)
      backdate(user, 59)
      assert Accounts.get_user_by_password_link(token)
      backdate(user, 61)
      refute Accounts.get_user_by_password_link(token)
      assert {:error, :invalid} = set(token)
      refute Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "ends with a change of address, and with the account's deletion",
         %{admin: admin, user: user} do
      {token, _} = make(admin, user)
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: unique_user_email()])
      refute Accounts.get_user_by_password_link(token)
      assert {:error, :invalid} = set(token)

      other = account()
      {token, _} = make(admin, other)
      {:ok, _} = Accounts.delete_user(%Scope{user: other})
      assert {:error, :invalid} = set(token)
    end

    test "a token that is none, or a log-in link's, does nothing", %{user: user} do
      {login, _hash} = generate_user_magic_link_token(user)

      for token <- ["", "not base64!", Base.url_encode64(:crypto.strong_rand_bytes(32)), login] do
        refute Accounts.get_user_by_password_link(token)
        assert {:error, :invalid} = set(token)
      end

      refute Accounts.get_user_by_email_and_password(user.email, @password)
    end
  end
end

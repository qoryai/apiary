defmodule Apiary.ReleasePasswordLinkTest do
  @moduledoc """
  The release commands' password links: `Apiary.Release.password_link/1`, for whoever runs
  the instance, mail or not, and `Apiary.Release.grant_instance_admin/2`'s claim of an
  instance nobody has signed up to while no mail is set, which prints one in place of the
  log-in link it would email. Each prints the link and when it stops working on the
  terminal, never the address, and the link works once, for an hour.
  """
  # Not async: the commands act on the suite's instance organisation, which every test
  # shares, and a claim hides it inside the test's sandbox (`Apiary.EditionKit`).
  use Apiary.DataCase, async: false

  import ExUnit.CaptureIO
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Accounts, Release}
  alias Apiary.Accounts.{Scope, UserToken}
  alias Apiary.Audit.Entry

  @password "a long pass phrase"

  defp run(fun) do
    send(self(), {:result, nil})
    output = capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, nil}
    assert_received {:result, result}
    {result, output}
  end

  defp link_in(output) do
    assert [url] = Regex.run(~r{https?://\S+/users/password/[A-Za-z0-9_-]+}, output)
    url |> String.split("/") |> List.last()
  end

  defp set(token),
    do:
      Accounts.set_password_by_link(token, %{
        "password" => @password,
        "password_confirmation" => @password
      })

  describe "password_link/1" do
    test "prints a link for an hour, never the address; the link sets the password once" do
      user = user_fixture()

      for source <- [:env, :none] do
        Apiary.Mail.put_test_source(source)
        {result, output} = run(fn -> Release.password_link(" #{user.email} ") end)

        assert result == {:ok, user.id}
        assert output =~ "A password link for the account #{user.id}"
        assert output =~ "UTC"
        refute output =~ user.email

        token = link_in(output)

        assert [%UserToken{context: "password:release"}] =
                 Repo.all(
                   from t in UserToken,
                     where: t.user_id == ^user.id and t.context == "password:release"
                 )

        assert {:ok, _} = set(token)
        assert {:error, :invalid} = set(token)
      end

      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "is an entry by the instance, from the command, without the link" do
      user = user_fixture()
      {_result, output} = run(fn -> Release.password_link(user.email) end)
      token = link_in(output)

      assert [entry] = Repo.all(from e in Entry, where: e.action == "account.password_link")
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.worker == "Apiary.Release.password_link/1"
      assert entry.details["user_id"] == user.id
      refute inspect(entry) =~ token
    end

    test "an address no account has: says so, and makes nothing" do
      {result, output} = run(fn -> Release.password_link("nobody@example.com") end)

      assert result == {:error, :not_found}
      assert output =~ "No account has that email address"
      assert Repo.all(from e in Entry, where: e.action == "account.password_link") == []
    end
  end

  describe "grant_instance_admin/2 on an instance nobody has signed up to, without mail" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      Apiary.Mail.put_test_source(:none)
      :ok
    end

    test "claims it and prints a password link for the first admin, not the address" do
      {result, output} =
        run(fn -> Release.grant_instance_admin("claim-nomail@example.com", "Acme Hosting") end)

      assert result == {:ok, :created_without_mail}
      user = Accounts.get_user_by_email("claim-nomail@example.com")
      assert Access.instance_admin?(Scope.for_user(user))

      assert output =~ "The account #{user.id} is the instance's first admin"
      assert output =~ "No mail is set"
      refute output =~ "claim-nomail"
      refute output =~ "/users/log-in"
      refute_received {:email, _}

      # The link is the release command's, by the instance, from the agreed worker.
      token = link_in(output)
      assert %{id: id} = Accounts.get_user_by_password_link(token)
      assert id == user.id

      assert [entry] = Repo.all(from e in Entry, where: e.action == "account.password_link")
      assert entry.worker == "Apiary.Release.grant_instance_admin/2"
      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}

      assert {:ok, _} = set(token)
      assert Accounts.get_user_by_email_and_password("claim-nomail@example.com", @password)
    end
  end

  describe "grant_instance_admin/2 on an instance nobody has signed up to, with mail" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "emails the log-in link as before, and prints no password link" do
      {result, output} =
        run(fn -> Release.grant_instance_admin("claim-mail@example.com", "Acme Hosting") end)

      assert result == {:ok, :created}
      assert_received {:email, %Swoosh.Email{to: [{"", "claim-mail@example.com"}]}}
      refute output =~ "/users/password/"
      assert Repo.all(from e in Entry, where: e.action == "account.password_link") == []
    end
  end

  test "granting an account on an instance that has its organisation prints no link" do
    %{user: user} = sign_up_fixture()
    Apiary.Mail.put_test_source(:none)

    {result, output} = run(fn -> Release.grant_instance_admin(user.email) end)

    assert {:ok, _membership} = result
    refute output =~ "/users/password/"
  end
end

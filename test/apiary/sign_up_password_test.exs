defmodule Apiary.SignUpPasswordTest do
  @moduledoc """
  A sign-up's password (`Apiary.Organisations.sign_up_user/3`): required while the
  instance sends no email (`Apiary.Mail.configured?/0`), optional once it does, and never
  asked of the instance's own sign-ups (`actor: :instance`). Without mail, an invited
  sign-up keeps the invitation's address. Each test sets the mail source for its own
  process (`Apiary.Mail.put_test_source/1`); an invitation is made first, while the
  suite's mail is on.
  """
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts
  alias Apiary.Accounts.User
  alias Apiary.Audit.Entry
  alias Apiary.Organisations

  @password "a long pass phrase"

  defp attrs(extra \\ %{}), do: valid_user_attributes(extra)

  defp sign_up(attrs, token \\ nil, opts \\ [open: true]),
    do: Organisations.sign_up_user(attrs, token, opts)

  describe "without mail" do
    setup do
      Apiary.Mail.put_test_source(:none)
    end

    test "a sign-up without a password is refused on the password, and nothing is made" do
      %{email: email} = attrs = attrs()

      assert {:error, %Ecto.Changeset{} = form} = sign_up(attrs)
      assert "can't be blank" in errors_on(form).password
      refute Accounts.get_user_by_email(email)
    end

    test "a sign-up with a password makes an unconfirmed account that signs in with it" do
      attrs = attrs(%{password: @password, password_confirmation: @password})

      assert {:ok, %{user: %User{} = user}} = sign_up(attrs)
      assert is_nil(user.confirmed_at)
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)

      assert %User{id: id} = Accounts.get_user_by_email_and_password(attrs.email, @password)
      assert id == user.id
      refute Accounts.get_user_by_email_and_password(attrs.email, "another pass phrase")
    end

    test "string keys, as a form sends them" do
      attrs = %{
        "email" => unique_user_email(),
        "organisation_name" => unique_organisation_name(),
        "password" => @password,
        "password_confirmation" => @password
      }

      assert {:ok, %{user: user}} = sign_up(attrs)
      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "the password is 12 to 72 characters, and its confirmation must match" do
      short = attrs(%{password: "too short", password_confirmation: "too short"})
      assert {:error, form} = sign_up(short)
      assert "should be at least 12 character(s)" in errors_on(form).password

      long = String.duplicate("x", 73)
      assert {:error, form} = sign_up(attrs(%{password: long, password_confirmation: long}))
      assert "should be at most 72 character(s)" in errors_on(form).password

      # 72 characters at most, but more than 72 bytes: Bcrypt reads 72 bytes.
      wide = String.duplicate("é", 40)
      assert {:error, form} = sign_up(attrs(%{password: wide, password_confirmation: wide}))
      assert "should be at most 72 byte(s)" in errors_on(form).password

      mismatch = attrs(%{password: @password, password_confirmation: "another pass phrase"})
      assert {:error, form} = sign_up(mismatch)
      assert "does not match password" in errors_on(form).password_confirmation
    end

    test "the form's changeset asks for the password" do
      form = Organisations.change_sign_up(%{"email" => unique_user_email()}, invited: true)
      refute form.valid?
      assert "can't be blank" in errors_on(form).password

      form =
        Organisations.change_sign_up(
          %{
            "email" => unique_user_email(),
            "password" => @password,
            "password_confirmation" => @password
          },
          invited: true
        )

      assert form.valid?
      # The password is checked, never kept in the form's changes.
      refute Map.has_key?(form.changes, :password)

      # 72 bytes at most, as the sign-up checks it: Bcrypt reads 72 bytes.
      wide = String.duplicate("é", 40)

      form =
        Organisations.change_sign_up(
          %{
            "email" => unique_user_email(),
            "password" => wide,
            "password_confirmation" => wide
          },
          invited: true
        )

      assert "should be at most 72 byte(s)" in errors_on(form).password
    end

    test "the password reaches no step of the edition's and no entry" do
      attrs = attrs(%{password: @password, password_confirmation: @password})
      assert {:ok, %{organisation: organisation}} = sign_up(attrs)

      entries = Repo.all(from e in Entry, where: e.organisation_id == ^organisation.id)
      assert entries != []
      refute inspect(entries) =~ @password
    end

    test "the instance's own sign-up asks for no password, and keeps one given" do
      assert {:ok, %{user: user}} =
               sign_up(attrs(), nil, open: true, actor: :instance, origin: %{worker: "test"})

      assert is_nil(user.hashed_password)

      attrs = attrs(%{password: @password, password_confirmation: @password})

      assert {:ok, %{user: user}} =
               sign_up(attrs, nil, open: true, actor: :instance, origin: %{worker: "test"})

      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "an invited sign-up keeps the invitation's address, whatever the form sent" do
      # The sign-up and the invitation before it are made with mail.
      Apiary.Mail.put_test_source(:env)
      %{scope: scope} = sign_up_fixture()
      invited = unique_user_email()
      %{token: token} = invitation_fixture(scope, %{"email" => invited})
      Apiary.Mail.put_test_source(:none)

      attrs = %{
        "email" => unique_user_email(),
        "password" => @password,
        "password_confirmation" => @password
      }

      assert {:ok, %{user: user, organisation: organisation}} = sign_up(attrs, token)
      assert user.email == invited
      assert organisation.id == scope.organisation.id
      assert Accounts.get_user_by_email_and_password(invited, @password)
    end
  end

  describe "with mail" do
    setup do
      Apiary.Mail.put_test_source(:env)
    end

    test "a sign-up without a password is made, as before" do
      assert {:ok, %{user: user}} = sign_up(attrs())
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
    end

    test "a person's sign-up drops a password sent all the same: the address is confirmed by email first" do
      # Not even checked: one that would be refused is dropped too.
      assert {:ok, %{user: user}} = sign_up(attrs(%{password: "too short"}))
      assert is_nil(user.hashed_password)

      attrs = attrs(%{"password" => @password, "password_confirmation" => @password})
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      assert {:ok, %{user: user}} = sign_up(attrs)
      assert is_nil(user.hashed_password)
      refute Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "an invited person's sign-up drops it too" do
      %{scope: scope} = sign_up_fixture()
      email = unique_user_email()
      %{token: token} = invitation_fixture(scope, %{"email" => email})

      attrs = %{"email" => email, "password" => @password, "password_confirmation" => @password}
      assert {:ok, %{user: user}} = sign_up(attrs, token)
      assert is_nil(user.hashed_password)
    end

    test "the form's changeset leaves the password out" do
      form =
        Organisations.change_sign_up(%{"email" => unique_user_email(), "password" => "short"},
          invited: true
        )

      assert form.valid?
    end

    test "the instance's own sign-up keeps a password given" do
      attrs = attrs(%{password: @password, password_confirmation: @password})

      assert {:ok, %{user: user}} =
               sign_up(attrs, nil, open: true, actor: :instance, origin: %{worker: "test"})

      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "an invited sign-up may change the address, as before" do
      %{scope: scope} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope, %{"email" => unique_user_email()})
      other = unique_user_email()

      assert {:ok, %{user: user}} = sign_up(%{"email" => other}, token)
      assert user.email == other
    end
  end
end

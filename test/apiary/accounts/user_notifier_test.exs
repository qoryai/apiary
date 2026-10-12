defmodule Apiary.Accounts.UserNotifierTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.UserNotifier
  alias Apiary.Organisations
  alias Apiary.Organisations.Organisation

  # A name an owner may type that reads like someone else's; a bare domain is allowed.
  @name "Example Bank Security acme.io"

  defp invite_from(scope, email) do
    {:ok, _invitation} =
      Organisations.invite_member(
        scope,
        %{"email" => email},
        &"http://localhost/invitations/#{&1}"
      )

    assert_received {:email, %Swoosh.Email{to: [{"", ^email}]} = email}
    email
  end

  test "an invitation names the organisation only inside a sentence Qory writes" do
    %{scope: scope, user: inviter} = sign_up_fixture()
    {:ok, organisation} = Organisations.update_organisation(scope, %{name: @name})
    email = invite_from(%{scope | organisation: organisation}, "dana@example.com")

    # Not in the subject, least of all at its start.
    assert email.subject == "Your invitation to Qory Apiary"
    refute email.subject =~ "Example"

    lines = email.text_body |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    # Once, in quotation marks, in the middle of Qory's sentence; never a line of its own,
    # as a heading would be.
    assert [sentence] = Enum.filter(lines, &(&1 =~ "Example Bank"))

    assert sentence ==
             "You are invited to join the organisation “#{@name}” on Qory Apiary. " <>
               "You can accept the invitation by visiting the URL below:"

    refute Enum.any?(lines, &(&1 == @name))

    # The link is the bare URL on a line of its own: no text of the owners' makes it.
    assert [link] = Enum.filter(lines, &String.starts_with?(&1, "http"))
    assert link =~ ~r{\Ahttp://localhost/invitations/[A-Za-z0-9_-]+\z}
    refute email.html_body

    # Nothing of the inviter's address, whose local part they chose.
    refute email.text_body =~ inviter.email
    refute email.text_body =~ inviter.email |> String.split("@") |> hd()
  end

  test "a name stored with format characters is sent without them, but the join controls" do
    organisation = %Organisation{name: "Acme\u202E\u200Bmoc.knab"}
    {:ok, email} = UserNotifier.deliver_invitation("dana@example.com", organisation, "http://x")

    assert email.text_body =~ "“Acmemoc.knab”"
    refute email.text_body =~ ~r/\p{Cf}/u

    joined = %Organisation{name: "می\u200Cخواهم 👨\u200D👩\u200D👧\u2066"}
    {:ok, email} = UserNotifier.deliver_invitation("dana@example.com", joined, "http://x")
    assert email.text_body =~ "“می\u200Cخواهم 👨\u200D👩\u200D👧”"
  end

  describe "with no mail set" do
    # A signed-up account, the fixture's own emails received and set aside.
    defp account do
      %{user: user} = sign_up_fixture()
      flush_emails()
      user
    end

    defp flush_emails do
      receive do
        {:email, _} -> flush_emails()
      after
        0 -> :ok
      end
    end

    test "nothing is sent, and the answer says so" do
      user = account()
      Apiary.Mail.put_test_source(:none)

      assert {:error, :no_mail} =
               Apiary.Accounts.deliver_login_instructions(user, &"http://localhost/#{&1}")

      assert {:error, :no_mail} =
               UserNotifier.deliver_invitation(
                 "dana@example.com",
                 %Organisation{name: "Acme"},
                 "http://localhost/invitations/x"
               )

      assert {:error, :no_mail} =
               UserNotifier.deliver_update_email_instructions(user, "http://localhost/x")

      refute_received {:email, _}
    end

    test "a process the test started sends nothing either" do
      user = account()
      Apiary.Mail.put_test_source(:none)

      task =
        Task.async(fn ->
          Apiary.Accounts.deliver_login_instructions(user, &"http://localhost/#{&1}")
        end)

      assert {:error, :no_mail} = Task.await(task)
      refute_received {:email, _}
    end

    test "mail from the settings is sent" do
      user = account()
      Apiary.Mail.put_test_source(:settings)

      assert {:ok, _email} =
               Apiary.Accounts.deliver_login_instructions(user, &"http://localhost/#{&1}")

      assert_received {:email, %Swoosh.Email{to: [{"", address}]}}
      assert address == user.email
    end
  end

  describe "an organisation's name" do
    # Each kind the name refuses, at creation and at rename, with its error.
    @refused [
      {"a scheme", "Bank https://bank.example", "must not contain a web address"},
      {"a scheme without http", "Bank ftp://files", "must not contain a web address"},
      {"www.", "Bank www.bank.example", "must not contain a web address"},
      {"WWW. in capitals", "WWW.BANK.EXAMPLE", "must not contain a web address"},
      {"straight quotes", ~s(Acme" and friends), "must not contain quotation marks"},
      {"curly quotes", "Acme “Bank”", "must not contain quotation marks"},
      {"low quotes", "Acme „Bank“", "must not contain quotation marks"},
      {"guillemets", "Acme «Bank»", "must not contain quotation marks"},
      {"single guillemets", "Acme ‹Bank›", "must not contain quotation marks"},
      {"a zero-width space", "Ac\u200Bme", "must not contain invisible characters"},
      {"a left-to-right mark", "Ac\u200Eme", "must not contain invisible characters"},
      {"a right-to-left mark", "Ac\u200Fme", "must not contain invisible characters"},
      {"a bidi embedding", "Ac\u202Ame", "must not contain invisible characters"},
      {"a bidi override", "Ac\u202Eme", "must not contain invisible characters"},
      {"a bidi isolate", "Ac\u2066me\u2069", "must not contain invisible characters"},
      {"a soft hyphen", "Ac\u00ADme", "must not contain invisible characters"},
      {"a tag character", "Acme\u{E0041}", "must not contain invisible characters"},
      {"a word joiner", "Ac\u2060me", "must not contain invisible characters"},
      {"a leading zero-width non-joiner", "\u200CAcme", "must not start or end"},
      {"a trailing zero-width joiner", "Acme\u200D", "must not start or end"},
      {"a double prime", "Acme ″Bank″", "must not contain quotation marks"},
      {"reversed double primes", "Acme ‶Bank‶", "must not contain quotation marks"},
      {"a high reversed double quote", "Acme ‟Bank", "must not contain quotation marks"},
      {"a fullwidth quote", "Acme ＂Bank＂", "must not contain quotation marks"},
      {"CJK double primes", "Acme 〝Bank〞", "must not contain quotation marks"},
      {"a Hebrew gershayim", "Acme ״Bank", "must not contain quotation marks"},
      {"a modifier double apostrophe", "Acme ˮBank", "must not contain quotation marks"},
      {"a modifier double prime", "Acme ʺBank", "must not contain quotation marks"},
      {"a reversed single quote", "Acme ‛Bank", "must not contain quotation marks"},
      {"a Pi or Pf mark", "Acme ⸂Bank⸃", "must not contain quotation marks"}
    ]

    for {kind, name, message} <- @refused do
      @tag name: name, message: message
      test "is refused with #{kind}, at sign-up and at rename", %{name: name, message: message} do
        assert {:error, changeset} =
                 Organisations.sign_up_user(%{
                   email: Apiary.AccountsFixtures.unique_user_email(),
                   organisation_name: name
                 })

        assert [error] = errors_on(changeset).organisation_name
        assert error =~ message

        %{scope: scope} = sign_up_fixture()
        assert {:error, changeset} = Organisations.update_organisation(scope, %{name: name})
        assert [error] = errors_on(changeset).name
        assert error =~ message
      end
    end

    test "may look like a domain, or have an apostrophe and a dot" do
      for name <- [
            "Acme.io",
            "acme.example.com",
            "O'Brien & Co.",
            "Dana’s",
            "O‘Brien’s",
            "Café Société",
            "wwwork",
            # Persian, with a zero-width non-joiner inside a word.
            "می\u200Cخواهم",
            # An emoji sequence joined by zero-width joiners.
            "Family 👨\u200D👩\u200D👧"
          ] do
        %{scope: scope} = sign_up_fixture()

        assert {:ok, %Organisation{name: ^name}} =
                 Organisations.update_organisation(scope, %{name: name})
      end
    end
  end
end

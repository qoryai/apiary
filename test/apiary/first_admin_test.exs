defmodule Apiary.FirstAdminTest do
  @moduledoc """
  The boot step that claims a fresh instance with `FIRST_ADMIN_EMAIL` and
  `FIRST_ORGANISATION_NAME` (`Apiary.FirstAdmin`): where it starts, what it claims, what it
  leaves alone, and the boots it stops. The suite's instance has had its first sign-up; a
  test hides its organisation inside its sandbox (`Apiary.EditionKit`). Two boots at once
  are in `Apiary.SignUpRacesTest`.
  """
  # Not async: the settings are the application's configuration, set for a test and put
  # back after it, and the step acts on the suite's instance organisation.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, FirstAdmin, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}

  # A relay that refuses the message with a reason that quotes it, as a real one may.
  defmodule LeakyFailingMailAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(email, _config),
      do: {:error, {:relay_said, "rejected #{inspect(email.to)}: #{email.text_body}"}}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:apiary, :first_admin_email_setting)
      Application.delete_env(:apiary, :first_organisation_name_setting)
    end)
  end

  defp settings(email, name) do
    Application.put_env(:apiary, :first_admin_email_setting, email)
    Application.put_env(:apiary, :first_organisation_name_setting, name)
  end

  # The boot's child, as the application's supervisor starts it: `:ignore`, or the exit
  # that takes the boot down, with the log it wrote.
  defp boot do
    log =
      capture_log(fn ->
        result =
          try do
            FirstAdmin.start_link()
          catch
            :exit, reason -> reason
          end

        send(self(), {:boot, result})
      end)

    assert_received {:boot, result}
    {result, log}
  end

  defp instance_organisation do
    case Apiary.Edition.instance_organisation_id() do
      nil -> nil
      id -> Repo.get!(Organisation, id)
    end
  end

  defp membership(user),
    do:
      Repo.get_by(Membership,
        organisation_id: Apiary.Edition.instance_organisation_id(),
        user_id: user.id
      )

  defp flush_mail do
    receive do
      {:email, _email} -> flush_mail()
    after
      0 -> :ok
    end
  end

  defp users, do: Repo.aggregate(Apiary.Accounts.User, :count)

  test "starts after the key check and before the endpoint, once the edition's processes are up" do
    previous = Application.get_env(:apiary, Apiary.KeyCheck)
    Application.put_env(:apiary, Apiary.KeyCheck, enabled: true)
    on_exit(fn -> Application.put_env(:apiary, Apiary.KeyCheck, previous) end)

    children = Apiary.Application.children()
    at = &Enum.find_index(children, fn child -> child == &1 end)

    assert at.(Apiary.KeyCheck) < at.(FirstAdmin)
    assert at.(FirstAdmin) < at.(ApiaryWeb.Endpoint)
    assert at.(FirstAdmin) == at.(ApiaryWeb.Endpoint) - 1
    assert at.(Apiary.Repo) < at.(FirstAdmin)
  end

  test "starts once, as a worker the supervisor does not restart" do
    assert %{restart: :temporary, start: {FirstAdmin, :start_link, []}} =
             FirstAdmin.child_spec([])
  end

  describe "on an instance nobody has signed up to" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "claims it, as the release command does, before the step returns" do
      settings("first@example.com", "Acme")

      assert {:ignore, log} = boot()
      refute log =~ "first@example.com"

      organisation = instance_organisation()
      assert %Organisation{name: "Acme"} = organisation
      user = Apiary.Accounts.get_user_by_email("first@example.com")
      assert %Membership{level: :owner} = membership(user)
      assert Access.instance_admin?(Scope.for_user(user))
      assert [%{name: "Main"}] = Organisations.list_workspaces(Scope.for_instance(organisation))

      assert_received {:email, %Swoosh.Email{to: [{"", "first@example.com"}]} = email}
      assert email.text_body =~ ~r{/users/log-in/[A-Za-z0-9_-]+}

      # By the instance, as the release command's claim is, from the boot step.
      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.worker == "Apiary.FirstAdmin"
      assert entry.details["user_id"] == user.id
    end

    test "trims the values, as the other settings are" do
      settings("  first@example.com\n", " Acme ")

      assert {:ignore, _log} = boot()
      assert %Organisation{name: "Acme"} = instance_organisation()
      assert Apiary.Accounts.get_user_by_email("first@example.com")
    end

    test "claims it when the mail fails, and says to ask for a link, without the reason" do
      previous = Application.fetch_env!(:apiary, Apiary.Mailer)
      Application.put_env(:apiary, Apiary.Mailer, adapter: __MODULE__.LeakyFailingMailAdapter)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
      settings("first-bounce@example.com", "Acme")

      assert {:ignore, log} = boot()

      assert %Organisation{name: "Acme"} = instance_organisation()
      user = Apiary.Accounts.get_user_by_email("first-bounce@example.com")
      assert Access.instance_admin?(Scope.for_user(user))

      assert log =~
               "The account #{user.id} is the instance's first admin, but its log-in link " <>
                 "could not be sent. Check the mail settings, then ask for a link at "

      assert log =~ "/users/log-in."
      # The relay's reason quotes the message: none of it is logged.
      refute log =~ "first-bounce"
      refute log =~ "relay_said"
      refute log =~ ~r{/users/log-in/[A-Za-z0-9_-]+}
    end

    test "both empty: claims nothing, and the first sign-up stays the web's" do
      for {email, name} <- [{nil, nil}, {"", ""}, {" ", "\n"}] do
        settings(email, name)
        assert boot() == {:ignore, ""}
      end

      assert instance_organisation() == nil
      assert Organisations.sign_up_offer() == :first
      refute_received {:email, _}
    end

    test "an address the sign-up refuses stops the boot, naming the variable, and creates nothing" do
      users = users()
      settings("not an address", "Acme")

      assert {:first_admin_refused, log} = boot()

      assert log =~
               "environment variable FIRST_ADMIN_EMAIL is not valid: " <>
                 "must have the @ sign and no spaces."

      refute log =~ "FIRST_ORGANISATION_NAME"
      refute log =~ "not an address"
      assert instance_organisation() == nil
      assert users() == users
      refute_received {:email, _}
    end

    test "a name the sign-up refuses stops the boot, naming the variable, and creates nothing" do
      settings("first@example.com", "Bank https://bank.example")

      assert {:first_admin_refused, log} = boot()

      assert log =~
               "environment variable FIRST_ORGANISATION_NAME is not valid: " <>
                 "must not contain a web address; a name like acme.io is fine."

      refute log =~ "FIRST_ADMIN_EMAIL"
      refute log =~ "bank.example"
      assert instance_organisation() == nil
      refute Apiary.Accounts.get_user_by_email("first@example.com")
    end

    test "one set and the other empty stops the boot, naming the empty one" do
      for {email, name, missing, set} <- [
            {"first@example.com", nil, "FIRST_ORGANISATION_NAME", "FIRST_ADMIN_EMAIL"},
            {"first@example.com", " ", "FIRST_ORGANISATION_NAME", "FIRST_ADMIN_EMAIL"},
            {nil, "Acme", "FIRST_ADMIN_EMAIL", "FIRST_ORGANISATION_NAME"},
            {"", "Acme", "FIRST_ADMIN_EMAIL", "FIRST_ORGANISATION_NAME"}
          ] do
        settings(email, name)

        assert {:first_admin_refused, log} = boot()

        assert log =~
                 "environment variable #{missing} is empty, and #{set} is set. " <>
                   "Set both to claim this instance at its first start, or neither."
      end

      assert instance_organisation() == nil
      refute Apiary.Accounts.get_user_by_email("first@example.com")
    end
  end

  describe "on an instance that has its organisation" do
    test "does nothing, whatever the settings say" do
      organisation = instance_organisation()
      users = users()

      for {email, name} <- [
            {"first@example.com", "Acme"},
            {"not an address", "Acme"},
            {"first@example.com", nil}
          ] do
        settings(email, name)
        assert boot() == {:ignore, ""}
      end

      assert instance_organisation() == organisation
      assert users() == users
      refute_received {:email, _}
    end

    test "a restored one: grants nothing to the address, even when its account exists" do
      # A database restored from another instance's dump: its own organisation and owner.
      Apiary.EditionKit.hide_instance_organisation()
      %{organisation: restored} = sign_up_fixture()
      assert Apiary.Edition.instance_organisation_id() == restored.id

      # The address names an account of the restored instance, a member there.
      %{user: member} = sign_up_fixture()
      settings(member.email, "Acme")
      # The fixtures' own mail.
      flush_mail()

      assert boot() == {:ignore, ""}

      assert instance_organisation().id == restored.id
      refute membership(member)
      refute Access.instance_admin?(Scope.for_user(member))
      refute_received {:email, _}
    end
  end
end

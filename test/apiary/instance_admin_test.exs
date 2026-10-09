defmodule Apiary.InstanceAdminTest do
  @moduledoc """
  The release command that claims an instance nobody has signed up to
  (`Apiary.Release.grant_instance_admin/2`): it is the instance's first sign-up, which
  creates the instance's organisation (`c:Apiary.Edition.instance_organisation_id/0`), and
  its owner is the instance's first admin (`Apiary.Access.instance_admin?/1`). The suite's
  instance has had its first sign-up; a test hides its organisation inside its sandbox
  (`Apiary.EditionKit`).
  """
  # Not async: the release command acts on the suite's instance organisation, which every
  # test shares.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureIO
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Organisations, Release}
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

  # The instance's organisation, as it is now; nil before the instance's first sign-up.
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

  defp quietly(fun) do
    send(self(), {:result, nil})
    capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, nil}
    assert_received {:result, result}
    result
  end

  describe "grant_instance_admin/2 on an instance nobody has signed up to" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "claims it: the first sign-up, with its log-in link" do
      assert {:ok, :created} =
               quietly(fn ->
                 Release.grant_instance_admin("claim@example.com", "Acme Hosting")
               end)

      organisation = instance_organisation()
      assert %Organisation{name: "Acme Hosting"} = organisation
      user = Apiary.Accounts.get_user_by_email("claim@example.com")
      assert %Membership{level: :owner} = membership(user)
      assert Access.instance_admin?(Scope.for_user(user))
      assert [%{name: "Main"}] = Organisations.list_workspaces(Scope.for_instance(organisation))

      assert_received {:email, %Swoosh.Email{to: [{"", "claim@example.com"}]} = email}
      assert email.text_body =~ ~r{/users/log-in/[A-Za-z0-9_-]+}

      # The organisation.create entry is the command's: by the instance, from its worker,
      # naming the account it made the owner.
      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.worker == "Apiary.Release.grant_instance_admin/2"
      assert entry.details["user_id"] == user.id
      assert entry.details["membership_id"] == membership(user).id

      # Once claimed, the command grants, and the name is not read.
      %{user: other} = sign_up_fixture()

      assert {:ok, %Membership{}} =
               quietly(fn -> Release.grant_instance_admin(other.email, "X") end)

      assert %Organisation{name: "Acme Hosting"} = instance_organisation()
      assert instance_organisation().id == organisation.id
    end

    test "prints neither the address nor the link" do
      output =
        capture_io(fn ->
          assert {:ok, :created} =
                   Release.grant_instance_admin("claim-quiet@example.com", "Acme Hosting")
        end)

      assert_received {:email, %Swoosh.Email{} = email}
      [_, token] = Regex.run(~r{/users/log-in/([A-Za-z0-9_-]+)}, email.text_body)

      assert output =~ "first admin"
      refute output =~ "claim-quiet"
      refute output =~ token
      refute output =~ "/users/log-in/"
    end

    test "claims it when the mail fails, and says to ask for a link, without the reason" do
      previous = Application.fetch_env!(:apiary, Apiary.Mailer)
      Application.put_env(:apiary, Apiary.Mailer, adapter: __MODULE__.LeakyFailingMailAdapter)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)

      output =
        capture_io(fn ->
          assert {:ok, :created_without_mail} =
                   Release.grant_instance_admin("claim-bounce@example.com", "Acme Hosting")
        end)

      assert %Organisation{name: "Acme Hosting"} = instance_organisation()
      user = Apiary.Accounts.get_user_by_email("claim-bounce@example.com")
      assert Access.instance_admin?(Scope.for_user(user))

      assert output =~ "could not be sent"
      assert output =~ "/users/log-in."
      # The relay's reason quotes the message: none of it is printed.
      refute output =~ "claim-bounce"
      refute output =~ "relay said"
      refute output =~ ~r{/users/log-in/[A-Za-z0-9_-]+}
    end

    test "without an organisation's name, is refused and creates nothing" do
      for name <- [nil, ""] do
        assert {:error, :organisation_name_required} =
                 quietly(fn -> Release.grant_instance_admin("claim@example.com", name) end)
      end

      assert instance_organisation() == nil
      refute Apiary.Accounts.get_user_by_email("claim@example.com")
      refute_received {:email, _}
    end

    test "an address or a name the sign-up refuses is refused, and creates nothing" do
      assert {:error, :invalid} =
               quietly(fn -> Release.grant_instance_admin("not an address", "Acme") end)

      assert {:error, :invalid} =
               quietly(fn ->
                 Release.grant_instance_admin("claim@example.com", "Bank https://bank.example")
               end)

      assert instance_organisation() == nil
    end

    test "an address an account has already is refused with the sign-up's message" do
      # An account in no organisation, as one left after its own was deleted.
      existing = Apiary.AccountsFixtures.user_fixture()

      output =
        capture_io(fn ->
          assert {:error, :invalid} = Release.grant_instance_admin(existing.email, "Acme")
        end)

      assert output == "Not created: email has already been taken.\n"
      assert instance_organisation() == nil
    end
  end
end

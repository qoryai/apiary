defmodule Apiary.InvitationWithoutWorkspaceRaceTest do
  # An invitation without a workspace and the organisation's first workspace at once, each
  # on a connection of its own, outside the SQL sandbox (`Apiary.Races`): the invitation
  # is checked again under the organisation's lock, so the workspace that came first is
  # seen. Two first workspaces at once: of the two, one is created. Not async: what these tests commit is visible to every other test while they
  # run, and they delete it again before they end.
  use ExUnit.Case, async: false

  import Apiary.Races
  import Ecto.Query

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Workspace}

  setup_all :clean_up_leftovers
  setup :setup_races

  # Without mail, an invitation makes a link to copy and asks for no confirmed inviter.
  setup do
    Apiary.Mail.put_test_source(:none)
    :ok
  end

  # The owner of a fresh organisation of the races' with no workspace, at the
  # organisation alone.
  defp without_workspace do
    {:ok, %{user: user, organisation: organisation, workspace: nil}} =
      Organisations.sign_up_user(
        %{
          email: email(),
          organisation_name: name("No workspace"),
          password: "hello world!",
          password_confirmation: "hello world!"
        },
        nil,
        open: true,
        workspace: false
      )

    created(%{organisation: organisation, user: user})
    Organisations.load_scope(Scope.for_user(user))
  end

  defp invite(scope),
    do: Organisations.invite_member(scope, %{"email" => email()}, &"http://localhost/#{&1}")

  defp invitations(%Scope{organisation: %{id: id}}),
    do: Repo.all(from i in Invitation, where: i.organisation_id == ^id)

  test "a first workspace created while an invitation waits on its lock refuses the invitation" do
    scope = without_workspace()

    {creation, holder} =
      hold(fn -> Organisations.create_first_workspace(scope, %{"domain" => "software"}) end)

    assert {:ok, %Workspace{}} = creation.result

    invitation = start(fn -> invite(scope) end)
    await_blocked(invitation.backend, holder)
    commit(creation)

    assert {:error, :not_found} = Task.await(invitation.task, 10_000)
    assert invitations(scope) == []
  end

  test "an invitation written first holds the first workspace back until it commits" do
    scope = without_workspace()

    {sent, holder} = hold(fn -> invite(scope) end)
    assert {:ok, %Invitation{workspace_id: nil}, {:link, _url}} = sent.result

    creation =
      start(fn -> Organisations.create_first_workspace(scope, %{"domain" => "software"}) end)

    await_blocked(creation.backend, holder)
    commit(sent)

    assert {:ok, %Workspace{}} = Task.await(creation.task, 10_000)
    assert [%Invitation{workspace_id: nil}] = invitations(scope)
  end

  test "of two first workspaces created at once, under two names, one is created" do
    scope = without_workspace()

    attrs = &%{"name" => &1, "domain" => "software"}

    {first, holder} =
      hold(fn -> Organisations.create_first_workspace(scope, attrs.("Payments")) end)

    assert {:ok, %Workspace{name: "Payments"}} = first.result

    second = start(fn -> Organisations.create_first_workspace(scope, attrs.("Billing")) end)
    await_blocked(second.backend, holder)
    commit(first)

    assert {:error, :exists} = Task.await(second.task, 10_000)

    assert [%Workspace{name: "Payments"}] =
             Repo.all(from w in Workspace, where: w.organisation_id == ^scope.organisation.id)
  end
end

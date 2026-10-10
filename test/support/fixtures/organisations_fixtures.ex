defmodule Apiary.OrganisationsFixtures do
  @moduledoc """
  Test helpers for organisations, workspaces, memberships and invitations, created the way the product creates them: through
  `Apiary.Organisations.sign_up_user/2` and the context's functions. The one exception is
  a second workspace (`workspace_fixture/2`), inserted whatever the edition's limit says,
  since the core's allows one.

  The suite's instance is set up before any test runs (`ensure_instance_organisation!/0`,
  from `test/test_helper.exs`), so a sign-up in a test is a later one.
  """

  import Ecto.Query

  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.AccountsFixtures
  alias Apiary.Organisations
  alias Apiary.Organisations.{Membership, Organisation, Slug, Workspace}
  alias Apiary.Repo

  @doc """
  Signs a user up, confirms them, and returns the user, organisation, workspace,
  membership and a loaded scope. With `invitation_token: token` the sign-up
  accepts that invitation instead of creating an organisation. Without one it is a later
  sign-up, which the fixture makes whether or not the edition opens one (`open: true`,
  `Apiary.Organisations.sign_up_user/3`); or, on an instance a test shows as not set up,
  its set-up (`Apiary.Setup.set_up/3`).
  """
  def sign_up_fixture(attrs \\ %{}) do
    {token, attrs} = Map.pop(attrs, :invitation_token)
    attrs = AccountsFixtures.valid_user_attributes(attrs)

    {:ok, %{user: user, organisation: organisation, workspace: workspace, membership: membership}} =
      if is_nil(token) and not Apiary.Setup.set_up?(),
        do: Apiary.Setup.set_up(Apiary.Setup.code!(), attrs),
        else: Organisations.sign_up_user(attrs, token, open: true)

    user = confirm_user(user)

    %{
      user: user,
      organisation: organisation,
      workspace: workspace,
      membership: membership,
      scope: Organisations.load_scope(Scope.for_user(user))
    }
  end

  def organisation_fixture(attrs \\ %{}), do: sign_up_fixture(attrs).organisation

  @doc "A loaded scope for a fresh owner of a fresh organisation."
  def scope_fixture(attrs \\ %{}), do: sign_up_fixture(attrs).scope

  @doc """
  The instance's own organisation (`c:Apiary.Edition.instance_organisation_id/0`), created
  once by the instance's set-up (`Apiary.Setup.set_up/3`), the way the product creates
  it, and committed, outside any test's sandbox: every test sees it, so the instance is
  set up for every test.
  """
  def ensure_instance_organisation! do
    organisation =
      case Apiary.Edition.instance_organisation_id() do
        nil ->
          {:ok, %{organisation: organisation}} =
            Apiary.Setup.set_up(Apiary.Setup.code!(), %{
              email: "instance-admin@example.com",
              organisation_name: "The suite's instance"
            })

          # The set-up's row of the instance's settings goes: the suite's database holds
          # none, as the key check's tests of a first boot expect (`Apiary.KeyCheckTest`).
          Repo.query!("DELETE FROM instance_settings")
          organisation

        id ->
          Repo.get!(Organisation, id)
      end

    # Its admin has signed in, as a person who signed up has by the time they act: their
    # account is confirmed, whichever run of the suite created it.
    for %{user: %{confirmed_at: nil} = user} <-
          Repo.all(
            from m in Membership,
              where: m.organisation_id == ^organisation.id,
              preload: :user
          ),
        do: confirm_user(user)

    organisation
  end

  @doc "A pending invitation into the scope's workspace, with the URL token the email carried."
  def invitation_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{"email" => AccountsFixtures.unique_user_email()})

    parent = self()
    ref = make_ref()

    {:ok, invitation} =
      Organisations.invite_member(scope, attrs, fn token ->
        send(parent, {ref, token})
        "http://localhost/invitations/#{token}"
      end)

    token =
      receive do
        {^ref, token} -> token
      after
        0 -> flunk_no_token()
      end

    %{invitation: invitation, token: token}
  end

  @doc """
  Another workspace of `organisation`, named `name`, inserted directly: the product
  creates one through `Apiary.Organisations.create_workspace/2`, as many as the edition's
  limit allows, which in the core's edition is the one the organisation was made with. Its
  owners and admins reach it, as they reach every workspace of their organisation.
  """
  def workspace_fixture(%Organisation{} = organisation, name \\ nil) do
    name = name || "Workspace #{System.unique_integer([:positive])}"

    %Workspace{organisation_id: organisation.id}
    |> Workspace.create_changeset(%{name: name, domain: "software"})
    |> Workspace.put_slug(Slug.from_name(name, "workspace"))
    |> Repo.insert!()
  end

  @doc """
  The scope of `user` in `workspace` of its organisation, as a page of its path loads it;
  nil where the user does not reach it.
  """
  def workspace_scope(user, %Workspace{} = workspace) do
    organisation = Repo.get!(Organisation, workspace.organisation_id)

    case Organisations.resolve_scope(Scope.for_user(user), organisation.slug, workspace.slug) do
      {:ok, scope} -> scope
      :error -> nil
    end
  end

  @doc """
  A second user who joined the scope's workspace through an invitation, as a member, and
  was then made `level` by the scope's person, an owner, as the members page makes them.
  """
  def member_fixture(%Scope{} = scope, level \\ :member) do
    email = AccountsFixtures.unique_user_email()
    %{token: token} = invitation_fixture(scope, %{"email" => email})
    signed_up = sign_up_fixture(%{email: email, invitation_token: token})

    case level do
      :member ->
        signed_up

      level ->
        {:ok, membership} =
          Organisations.set_member_level(scope, signed_up.membership.id, level)

        %{
          signed_up
          | membership: membership,
            scope: Organisations.load_scope(Scope.for_user(signed_up.user))
        }
    end
  end

  @doc """
  The existing account `user` joined the scope's workspace through an invitation, as a
  member: the membership, and `scope`, theirs in that workspace.
  """
  def join_fixture(%Scope{} = scope, user) do
    %{token: token} = invitation_fixture(scope, %{"email" => user.email})
    {:ok, membership} = Organisations.accept_invitation(user, token)
    %{membership: membership, scope: workspace_scope(user, scope.workspace)}
  end

  defp confirm_user(user) do
    token =
      AccountsFixtures.extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} = Accounts.login_user_by_magic_link(token)
    user
  end

  defp flunk_no_token, do: raise("invite_member did not call the URL function")
end

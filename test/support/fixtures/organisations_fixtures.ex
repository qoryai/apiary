defmodule Apiary.OrganisationsFixtures do
  @moduledoc """
  Test helpers for organisations, workspaces, memberships and invitations, all
  created the way the product creates them: through `Apiary.Organisations.sign_up_user/2`.
  """

  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.AccountsFixtures
  alias Apiary.Organisations

  @doc """
  Signs a user up, confirms them, and returns the user, organisation, workspace,
  membership and a loaded scope. With `invitation_token: token` the sign-up
  accepts that invitation instead of creating an organisation.
  """
  def sign_up_fixture(attrs \\ %{}) do
    {token, attrs} = Map.pop(attrs, :invitation_token)

    {:ok, %{user: user, organisation: organisation, workspace: workspace, membership: membership}} =
      attrs
      |> AccountsFixtures.valid_user_attributes()
      |> Organisations.sign_up_user(token)

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

  @doc "A pending invitation into the scope's workspace, with the URL token the email carried."
  def invitation_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{"email" => AccountsFixtures.unique_user_email(), "level" => "member"})

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

  @doc "A second user who joined the scope's workspace through an invitation, at `level`."
  def member_fixture(%Scope{} = scope, level \\ :member) do
    email = AccountsFixtures.unique_user_email()

    %{token: token} =
      invitation_fixture(scope, %{"email" => email, "level" => Atom.to_string(level)})

    sign_up_fixture(%{email: email, invitation_token: token})
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

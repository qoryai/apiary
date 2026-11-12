defmodule ApiaryProWeb.ClientLive.InvitationStepsTest do
  @moduledoc """
  The steps list of an invitation read signed out, on the sign-up page with `?invitation=`
  and on `/invitations/:token`. The workspace's steps (Name to Test run) are set up inside
  the workspace, so no list here has them. A client's invitation, while the client has no
  workspace, lists Invitation alone, so the page shows no steps indicator (the core shows it
  from two steps). Any other invitation lists Invitation, then Your account. The list is the
  same with `ApiaryPro.Flags.operator_infrastructure?/0` on and off.
  """
  # Not async: the features and the flag are the node's, and an operator is made by an
  # instance admin, an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import Apiary.OrganisationsFixtures, only: [invitation_fixture: 2, sign_up_fixture: 0]
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()

    {%{organisation: client}, token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    %{client: client, token: token, operator: operator}
  end

  # The labels of the steps, in their order.
  defp step_labels(lv) do
    lv
    |> element("#set-up-step-list")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".q-su-nm")
    |> Enum.map(&LazyHTML.text/1)
  end

  # The invitation of an organisation that is no client, which has no workspace.
  defp ordinary_invitation_token do
    open!([:organisation])
    %{scope: scope} = sign_up_fixture()

    {:ok, %{organisation: organisation}} =
      ApiaryPro.Organisations.create_organisation(scope, %{"name" => "Kestrel Works"})

    %{token: token} =
      invitation_fixture(scope_in(scope.user, organisation), %{"email" => unique_user_email()})

    token
  end

  for {flag, state} <- [{false, "off"}, {true, "on"}] do
    test "a client's invitation: the sign-up page lists Invitation alone, so it shows no indicator, with the flag #{state}",
         %{conn: conn, token: token} do
      Flags.put_operator_infrastructure(unquote(flag))
      {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")

      assert html =~ "You are invited to"
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-steps-account")
      refute has_element?(lv, "#set-up-steps-name")
      refute has_element?(lv, ".q-su-note")
    end

    test "a client's invitation: the invitation page lists the same, with the flag #{state}",
         %{conn: conn, token: token} do
      Flags.put_operator_infrastructure(unquote(flag))
      {:ok, lv, html} = live(conn, ~p"/invitations/#{token}")

      assert html =~ "Acme"
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-steps-account")
      refute has_element?(lv, "#set-up-steps-name")
      refute has_element?(lv, ".q-su-note")
    end

    @tag with_features: Features.all() -- [:factory, :workflow_model]
    test "a client's invitation: both pages show no indicator without the factory feature, with the flag #{state}",
         %{conn: conn, token: token} do
      Flags.put_operator_infrastructure(unquote(flag))

      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      refute has_element?(lv, "#set-up-steps")

      {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")
      refute has_element?(lv, "#set-up-steps")
    end

    test "the invitation to a workspace of a client lists Your account alone, so it shows no indicator, with the flag #{state}",
         %{conn: conn, operator: operator} do
      Flags.put_operator_infrastructure(unquote(flag))
      full = client_fixture(operator.scope, "Beta")

      %{token: token} =
        invitation_fixture(scope_in(full.owner.user, full.organisation), %{
          "email" => unique_user_email()
        })

      {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")
      assert html =~ "You are invited to the"
      refute has_element?(lv, "#set-up-steps")

      {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")
      refute has_element?(lv, "#set-up-steps")
    end
  end

  describe "the invitation of an organisation that is no client" do
    test "lists Invitation, then Your account, on both pages", %{conn: conn} do
      token = ordinary_invitation_token()

      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      assert step_labels(lv) == ["Invitation", "Your account"]
      assert has_element?(lv, "#set-up-steps-account[aria-current=step]", "Your account")

      {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")
      assert step_labels(lv) == ["Invitation", "Your account"]
      assert has_element?(lv, "#set-up-steps-invitation[aria-current=step]", "Invitation")
    end
  end
end

defmodule ApiaryProWeb.UserAuthTest do
  @moduledoc """
  The path's scope under workspace access: a member of an organisation reaches only the
  workspaces they were added to, and a page of another is not found.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts
  alias ApiaryWeb.UserAuth
  alias Phoenix.LiveView

  describe "on_mount :load_path_scope" do
    setup %{conn: conn} do
      %{user: user} = signed_up = sign_up_fixture()
      token = Accounts.generate_user_session_token(user)

      session =
        conn
        |> Map.replace!(:secret_key_base, ApiaryWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> put_session(:user_token, token)
        |> get_session()

      %{session: session, signed_up: signed_up}
    end

    test "raises not found for a workspace of the organisation the member was not added to",
         %{session: session, signed_up: signed_up} do
      %{user: member} = member_fixture(signed_up.scope, :member)
      platform = workspace_fixture(signed_up.organisation, "Platform")
      token = Accounts.generate_user_session_token(member)
      session = Map.put(session, "user_token", token)
      params = %{"org" => signed_up.organisation.slug, "workspace" => platform.slug}
      socket = %LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert_raise ApiaryWeb.NotFound, fn ->
        UserAuth.on_mount(:load_path_scope, params, session, socket)
      end
    end
  end
end

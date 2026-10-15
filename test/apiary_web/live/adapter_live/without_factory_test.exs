defmodule ApiaryWeb.AdapterLive.WithoutFactoryTest do
  # An instance without the feature integrations belong to: their pages are not there, as
  # a path the router does not know, and a pool's settings do not ask Served by. Not
  # async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures

  alias Apiary.AccessKeys

  alias ApiaryWeb.AdapterRoutes

  @endpoint AdapterRoutes.Endpoint

  # The integration is made where the feature is on, before it is turned off.
  @moduletag needs: :factory

  @without [:observability, :security]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    AdapterRoutes.start!()
    adapter = adapter_fixture(scope, name: "GitHub")
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, adapter)
    {:ok, code, _secret} = AccessKeys.create_enrolment_code(scope, adapter, %{})
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse(Enum.map_join(@without, ",", &to_string/1))
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    %{adapter: adapter, pool: pool, key: key, code: code}
  end

  test "the integrations' pages and the paths of their acts are not found",
       %{conn: conn, scope: scope, adapter: adapter, key: key, code: code} do
    list = "/#{scope.organisation.slug}/settings/integrations"
    page = list <> "/#{adapter.public_id}"

    for path <- [
          list,
          list <> "/new",
          page,
          page <> "/node-pools",
          page <> "/access-key",
          page <> "/access-key/new-code",
          page <> "/access-key/keys/#{key.key_id}/revoke",
          page <> "/access-key/codes/#{code.id}/revoke",
          page <> "/settings",
          page <> "/settings/rename",
          page <> "/settings/remove"
        ] do
      assert get(conn, path).status == 404
    end
  end

  test "a pool's settings do not ask Served by", %{conn: conn, scope: scope, pool: pool} do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{pool}/settings")

    assert has_element?(lv, "#node-form")
    refute has_element?(lv, "#node-form select[name='node[served_by_id]']")
  end
end

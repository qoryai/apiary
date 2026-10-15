defmodule ApiaryWeb.AdapterLive.HiddenTest do
  # The integrations hidden from the person while a page of theirs is open, as an edition
  # may hide them (`Apiary.EditionStubs.HidesNamed`): an act asked then changes nothing,
  # and the page leaves (`ApiaryWeb.AdapterComponents.leave_when_hidden/2`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures

  alias Apiary.{AccessKeys, Adapters, Edition, EditionStubs, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias ApiaryWeb.AdapterRoutes

  @endpoint AdapterRoutes.Endpoint

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    AdapterRoutes.start!()
    :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
    :ok = EditionStubs.HidesNamed.put([])

    adapter = adapter_fixture(scope, name: "GitHub")
    %{access_key: key} = enrolled_key_fixture(scope, adapter)
    {:ok, code, _secret} = AccessKeys.create_enrolment_code(scope, adapter, %{})

    %{adapter: adapter, key: key, code: code}
  end

  defp hide(names), do: :ok = EditionStubs.HidesNamed.put(names)

  test "every act asked after the integrations were hidden changes nothing, and the page leaves",
       %{conn: conn, scope: scope, adapter: adapter, key: key, code: code} do
    list = "/#{scope.organisation.slug}/settings/integrations"
    page = list <> "/#{adapter.public_id}"
    tab = page <> "/access-key"

    acts = [
      {list <> "/new", :submit, "create", %{"adapter" => %{"name" => "Linear"}}},
      {page <> "/settings/rename", :submit, "rename", %{"adapter" => %{"name" => "Shop"}}},
      {page <> "/settings/remove", :click, "remove", %{}},
      {tab, :click, "create_code", %{}},
      {tab <> "/keys/#{key.key_id}/revoke", :click, "revoke", %{}},
      {tab <> "/codes/#{code.id}/revoke", :click, "revoke_code", %{}}
    ]

    for {path, how, event, params} <- acts do
      hide([])
      {:ok, view, _html} = live(conn, path)
      hide([:factory])

      case how do
        :submit -> render_submit(view, event, params)
        :click -> render_click(view, event, params)
      end

      {to, _flash} = assert_redirect(view)
      refute String.starts_with?(to, list), "#{event} on #{path}"
    end

    hide([])
    assert [%{name: "GitHub"}] = Adapters.list_adapters(scope)
    assert is_nil(Repo.get!(AccessKey, key.id).revoked_at)
    assert %{cancelled_at: nil} = Repo.get!(EnrolmentCode, code.id)
    assert Repo.aggregate(EnrolmentCode, :count) == 2
  end
end

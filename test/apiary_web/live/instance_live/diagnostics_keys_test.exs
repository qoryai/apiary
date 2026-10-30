defmodule ApiaryWeb.InstanceLive.DiagnosticsKeysTest do
  # Instance settings › Diagnostics keys (`ApiaryWeb.InstanceLive.DiagnosticsKeys`): the
  # section in the Instance level's menu, Get the command and its page, the key that
  # arrives, the list, Revoke… confirmed in place, the Activity sentences, and a path that
  # does not exist for anyone but an instance admin. Not async: a test of an instance
  # admin hides the instance's organisation, a row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}

  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  # The key the code brings, enrolled as the computer enrols it (`Apiary.AccessKeys.enrol/2`).
  defp enrol!(code, name) do
    pair = Apiary.AccessKeysFixtures.ed25519_key_pair()
    timestamp = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, name, timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    body =
      Jason.encode!(%{
        version: 1,
        code: code,
        name: name,
        public_key: pair.encoded,
        timestamp: timestamp,
        proof: proof
      })

    {:ok, request} = Enrolment.decode(body)
    {:ok, key} = AccessKeys.enrol(request)
    key
  end

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "is a section of the Instance level, after Nodes and before Mail", %{scope: scope} do
      keys = Enum.map(ApiaryWeb.Layouts.instance_sections(scope), & &1.key)
      assert [:diagnostics_keys, :mail, :configuration] = Enum.take(keys, -3)

      assert %{label: "Diagnostics keys", path: "/instance/diagnostics-keys"} =
               Enum.find(
                 ApiaryWeb.Layouts.instance_sections(scope),
                 &(&1.key == :diagnostics_keys)
               )
    end

    test "gets the command, waits for the key, lists it, and revokes it", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, html} = live(conn, ~p"/instance/diagnostics-keys")

      assert html =~
               ~r{<title[^>]*>\s*Diagnostics keys · Instance settings · Qory Apiary\s*</title>}

      assert has_element?(
               view,
               "#diagnostics-keys-empty",
               "This instance has no diagnostics key."
             )

      view |> element("#code-new-button") |> render_click()
      assert_patch(view, ~p"/instance/diagnostics-keys/new-code")

      command = view |> element("#code-issued-command") |> render()

      [_, code] =
        Regex.run(~r/qory apiary enrol \S+ (qecd_[0-9A-Z]{26}\.[A-Za-z0-9_-]+)/, command)

      assert String.ends_with?(code, "." <> SigningKey.fingerprint())
      assert has_element?(view, "#code-issued-waiting")

      # No path, title or flash carries the code.
      refute render(view) =~ ~r{<title[^>]*>[^<]*qecd_}

      key = enrol!(code, "laptop")
      assert has_element?(view, "#code-issued-arrived", "laptop is active.")
      refute has_element?(view, "#code-issued-command")

      {:ok, view, _html} = live(conn, ~p"/instance/diagnostics-keys")
      assert has_element?(view, "#key-#{key.key_id}-label", "laptop")
      assert has_element?(view, "#key-#{key.key_id}-maker", scope.user.email)
      assert has_element?(view, "#key-#{key.key_id}-used", "Never")

      view |> element("#key-#{key.key_id}-revoke") |> render_click()
      assert_patch(view, ~p"/instance/diagnostics-keys/#{key.key_id}/revoke")
      assert has_element?(view, "#key-#{key.key_id}-confirm", "Revoke laptop?")

      view |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_patch(view, ~p"/instance/diagnostics-keys")
      assert render(view) =~ "laptop is revoked."
      refute has_element?(view, "#key-#{key.key_id}")
      assert %AccessKey{revoked_at: %DateTime{}} = Repo.get!(AccessKey, key.id)
    end

    test "the command's page, opened again, has no code", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/instance/diagnostics-keys"}}} =
               live(conn, ~p"/instance/diagnostics-keys/new-code")
    end
  end

  describe "for anyone else" do
    setup :register_and_log_in_user

    test "the page does not exist, and the menu does not offer it", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :diagnostics_keys))

      for path <- ~w(/instance/diagnostics-keys /instance/diagnostics-keys/new-code) do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
      end
    end
  end
end

defmodule ApiaryProWeb.UserLive.InvitationLimitsTest do
  @moduledoc """
  The edition's sign-up page with an invitation is a page a link opens: each load counts against
  the client address's limit (`ApiaryWeb.AttemptLimits`) before the token is looked up,
  as on the core's pages, and past it a real token and an unknown one get the same answer.
  """
  # The limits come from the application environment, which every test shares: here the
  # numbers the module gives, not the test configuration's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias ApiaryWeb.AttemptLimits

  @message "Too many attempts. Try again in a few minutes."

  setup do
    config = Application.get_env(:apiary, AttemptLimits)
    Application.delete_env(:apiary, AttemptLimits)
    on_exit(fn -> Application.put_env(:apiary, AttemptLimits, config) end)

    %{scope: owner} = sign_up_fixture()
    %{token: token} = invitation_fixture(owner)
    %{token: token}
  end

  defp from(text) do
    {:ok, address} = :inet.parse_address(String.to_charlist(text))
    Plug.Test.put_peer_data(build_conn(), %{address: address, port: 4711, ssl_cert: nil})
  end

  # Spends what is left of the client's bucket.
  defp spend_page(client) do
    if AttemptLimits.link_page(client) == :ok, do: spend_page(client)
  end

  test "past a client's limit, a real token and an unknown one get the same answer, and the page without a token is not counted",
       %{token: token} do
    client = "198.51.100.60"

    {:ok, lv, _html} = live(from(client), ~p"/users/register?invitation=#{token}")
    assert has_element?(lv, "#registration_form")

    spend_page(client)

    for path <- [
          ~p"/users/register?invitation=#{token}",
          ~p"/users/register?invitation=not-a-token"
        ] do
      assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
               live(from(client), path)
    end

    assert {:ok, _lv, _html} = live(from(client), ~p"/users/register")

    # Another client address is not counted.
    {:ok, lv, _html} = live(from("198.51.100.61"), ~p"/users/register?invitation=#{token}")
    assert has_element?(lv, "#registration_form")
  end
end

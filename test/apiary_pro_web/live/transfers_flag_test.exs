defmodule ApiaryProWeb.TransfersFlagTest do
  @moduledoc """
  An owner's reading of the offer of the organisation's ownership pending
  (`organisation.withdraw_transfer`) while `ApiaryPro.Flags.transfers?/0` is off: not
  found for everyone; the action of an offer's lapse stays in the Action filter.
  """
  # The flag is set for this process (`ApiaryPro.Flags.put_transfers/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Features}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  setup do: Flags.put_transfers(false)

  defp settings(organisation), do: ~p"/#{organisation}/settings"
  defp ownership(organisation), do: ~p"/#{organisation}/settings/ownership"

  defp filter_options(conn, organisation) do
    {:ok, view, _html} = live(conn, "/#{organisation.slug}/audit-log")
    render_async(view)

    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#filter-action-form li")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the flag" do
    test "is off by default, and a process's override reaches the processes it starts" do
      Process.delete({Flags, :transfers})
      refute Flags.transfers?()

      Flags.put_transfers(true)
      assert Flags.transfers?()
      assert Task.await(Task.async(&Flags.transfers?/0))

      # Another process, started by no one who turned it on, keeps the default.
      parent = self()
      spawn(fn -> send(parent, {:flag, Flags.transfers?()}) end)
      assert_receive {:flag, false}

      Flags.put_transfers(false)
      refute Task.await(Task.async(&Flags.transfers?/0))
    end
  end

  describe "while it is off" do
    test "the action is not found, for the owner who would take it" do
      independent = sign_up_fixture()
      action = :"organisation.withdraw_transfer"

      assert Access.authorize(independent.scope, action, independent.organisation) ==
               {:error, :not_found}

      refute Access.can?(independent.scope, action, independent.organisation)
      assert Access.authorize(nil, action, independent.organisation) == {:error, :not_found}

      # Turned on, the same owner may again.
      Flags.put_transfers(true)
      assert Access.authorize(independent.scope, action, independent.organisation) == :ok
    end

    test "an organisation with no operator and no offer has no Ownership, whatever the flag",
         %{conn: conn} do
      independent = sign_up_fixture()
      organisation = independent.organisation
      conn = log_in_user(conn, independent.user)

      for on <- [false, true] do
        Flags.put_transfers(on)
        {:ok, lv, _html} = live(conn, settings(organisation))
        refute has_element?(lv, "#settings-tab-ownership")

        assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
                 live(conn, ownership(organisation))

        assert to == settings(organisation)
        assert error =~ "There is nothing about the ownership of"
      end
    end

    test "the Action filter keeps the withdrawal, whatever the flag", %{conn: conn} do
      independent = sign_up_fixture()
      conn = log_in_user(conn, independent.user)

      for on <- [false, true] do
        Flags.put_transfers(on)
        assert "Offer withdrawn" in filter_options(conn, independent.organisation)
      end
    end
  end
end

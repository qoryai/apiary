defmodule ApiaryProWeb.TransfersFlagTest do
  @moduledoc """
  Offering an organisation to an operator, withdrawing the offer, an operator's accepting
  an organisation offered to it and a client's leaving its operator while
  `ApiaryPro.Flags.transfers?/0` is off: not found for everyone, and nowhere offered, an
  offer made before included; their old audit entries still read.
  """
  # The flag is set for this process (`ApiaryPro.Flags.put_transfers/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Features}
  alias ApiaryPro.{Flags, Transfers}
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.Transfers.Transfer

  @moduletag with_features: Features.all()

  @hidden [
    :"organisation.transfer",
    :"organisation.withdraw_transfer",
    :"organisation.leave_operator",
    :"client.accept"
  ]

  setup do: Flags.put_transfers(false)

  defp settings(organisation), do: ~p"/#{organisation}/settings"
  defp ownership(organisation), do: ~p"/#{organisation}/settings/ownership"

  defp entry(organisation, action) do
    Apiary.Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id and e.action == ^Atom.to_string(action),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp audit_log(conn, organisation) do
    {:ok, view, _html} = live(conn, "/#{organisation.slug}/audit-log")
    render_async(view)
    view
  end

  # An offer of `offered` to `operator` made before the flag was off: its row alone, as
  # `ApiaryPro.Transfers` would have inserted it.
  defp offer_made_before(offered, operator) do
    Apiary.Repo.insert!(%Transfer{
      organisation_id: offered.organisation.id,
      kind: :to_operator,
      operator_id: operator.organisation.id,
      offered_by_id: offered.user.id
    })
  end

  defp operator_id(organisation), do: Apiary.Repo.get!(Tenant, organisation.id).operator_id

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp filter_options(view) do
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
    test "each action is not found, for the owners who would take it" do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      independent = sign_up_fixture()

      for action <- [:"organisation.transfer", :"organisation.withdraw_transfer"] do
        assert Access.authorize(independent.scope, action, independent.organisation) ==
                 {:error, :not_found}

        refute Access.can?(independent.scope, action, independent.organisation)
      end

      assert Access.authorize(
               client.owner.scope,
               :"organisation.leave_operator",
               client.organisation
             ) == {:error, :not_found}

      for action <- @hidden do
        assert Access.authorize(nil, action, independent.organisation) == {:error, :not_found}
      end

      assert Transfers.offer_to_operator(independent.scope, operator.organisation.slug) ==
               {:error, :not_found}

      assert Transfers.withdraw(independent.scope) == {:error, :not_found}

      assert Transfers.leave(client.owner.scope, operator.organisation.name) ==
               {:error, :not_found}

      # Turned on, the same owners may again.
      Flags.put_transfers(true)

      assert Access.authorize(
               independent.scope,
               :"organisation.transfer",
               independent.organisation
             ) == :ok

      assert Access.authorize(
               client.owner.scope,
               :"organisation.leave_operator",
               client.organisation
             ) == :ok
    end

    test "an offer made before is not accepted, through Access or Transfers" do
      operator = operator_fixture()
      offered = sign_up_fixture()
      offer_made_before(offered, operator)

      assert Access.authorize(operator.scope, :"client.accept", operator.organisation) ==
               {:error, :not_found}

      refute Access.can?(operator.scope, :"client.accept", operator.organisation)

      assert Transfers.accept_client(operator.scope, offered.organisation.id) ==
               {:error, :not_found}

      assert operator_id(offered.organisation) == nil
      assert Apiary.Repo.get_by(Transfer, organisation_id: offered.organisation.id)

      # Turned on, the operator's owner accepts it as today.
      Flags.put_transfers(true)
      assert Access.authorize(operator.scope, :"client.accept", operator.organisation) == :ok
      assert {:ok, _client} = Transfers.accept_client(operator.scope, offered.organisation.id)
      assert operator_id(offered.organisation) == operator.organisation.id
    end

    test "the Clients page leaves out an offer made before, and refuses its acceptance",
         %{conn: conn} do
      operator = operator_fixture()
      offered = sign_up_fixture()
      org = offered.organisation
      offer_made_before(offered, operator)
      conn = log_in_user(conn, operator.user)
      clients = ~p"/#{operator.organisation}/clients"
      offered_to = "Offered to #{operator.organisation.name}"

      {:ok, lv, _html} = live(conn, clients)
      render_async(lv)
      refute has_element?(lv, "#offers")
      refute has_element?(lv, "#offer-#{org.id}")
      refute has_element?(lv, "#offer-#{org.id}-accept")
      refute render(lv) =~ offered_to
      refute render(lv) =~ "Their owners offer these organisations"
      refute render(lv) =~ org.name

      # The confirmation's path is not there, and says nothing.
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/#{operator.organisation}/clients/offers/#{org.id}/accept")
      end

      # The event sent all the same accepts nothing.
      html = render_click(lv, "accept_client", %{"id" => org.id})
      assert html =~ "That offer is no longer pending"
      refute has_element?(lv, "#offer-#{org.id}-accept")
      assert operator_id(org) == nil

      # Turned on, the section, its sentence and Accept are back, and accept it as today.
      Flags.put_transfers(true)
      {:ok, lv, _html} = live(conn, clients)
      render_async(lv)
      assert has_element?(lv, "#offers h2", offered_to)
      assert has_element?(lv, "#offers p", "Their owners offer these organisations")
      assert has_element?(lv, "#offers #offer-#{org.id}", org.name)
      lv |> element("#offer-#{org.id}-accept") |> render_click()
      assert_patch(lv, ~p"/#{operator.organisation}/clients/offers/#{org.id}/accept")
      html = lv |> element("#offer-#{org.id}-confirm-button") |> render_click()
      assert html =~ "#{org.name} is a client of #{operator.organisation.name} now"
      assert operator_id(org) == operator.organisation.id
    end

    test "a client's Ownership names its operator, offers no Leave, and says who ends it",
         %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      name = operator.organisation.name
      conn = log_in_user(conn, client.owner.user)

      {:ok, lv, _html} = live(conn, settings(client.organisation))
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, lv, _html} = live(conn, ownership(client.organisation))
      assert has_element?(lv, "#operator-name", name)
      refute has_element?(lv, "#leave-operator")
      assert has_element?(lv, "#operator", "#{name} can end this at any time.")
      refute has_element?(lv, "#operator", "Either side")

      # The confirmation's path is not there, and says nothing.
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/#{client.organisation}/settings/ownership/leave")
      end

      # Turned on, the button and today's line are back.
      Flags.put_transfers(true)
      {:ok, lv, _html} = live(conn, ownership(client.organisation))
      assert has_element?(lv, "#leave-operator")
      assert has_element?(lv, "#operator", "Either side can end this at any time.")
    end

    test "an organisation with no operator has no Ownership, and its section sends to General",
         %{conn: conn} do
      independent = sign_up_fixture()
      organisation = independent.organisation
      conn = log_in_user(conn, independent.user)

      {:ok, lv, _html} = live(conn, settings(organisation))
      refute has_element?(lv, "#settings-tab-ownership")

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(conn, ownership(organisation))

      assert to == settings(organisation)
      assert error =~ "There is nothing about the ownership of"

      Flags.put_transfers(true)
      {:ok, lv, _html} = live(conn, settings(organisation))
      assert has_element?(lv, "#settings-tab-ownership")
    end

    test "the offer's page and the withdrawal's are not found, for every organisation",
         %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      independent = sign_up_fixture()

      for {user, organisation} <- [
            {independent.user, independent.organisation},
            {client.owner.user, client.organisation},
            {operator.user, operator.organisation}
          ],
          path <- ["transfer", "withdraw"] do
        assert_raise ApiaryWeb.NotFound, fn ->
          live(
            log_in_user(build_conn(), user),
            "/#{organisation.slug}/settings/ownership/#{path}"
          )
        end
      end

      # Turned on, the offer's page opens for an organisation with no operator, and a
      # client's owner is sent back with today's words.
      Flags.put_transfers(true)
      conn = log_in_user(conn, independent.user)
      {:ok, lv, _html} = live(conn, ~p"/#{independent.organisation}/settings/ownership/transfer")
      assert has_element?(lv, "#transfer-form")

      conn = log_in_user(build_conn(), client.owner.user)

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(conn, ~p"/#{client.organisation}/settings/ownership/transfer")

      assert to == ownership(client.organisation)
      assert error =~ "Only an owner offers the organisation to an operator"
    end

    test "the Action filter leaves out the offer, its acceptance and the leaving, and keeps the withdrawal",
         %{conn: conn} do
      independent = sign_up_fixture()
      operator = operator_fixture()
      conn = log_in_user(conn, independent.user)
      operator_conn = log_in_user(build_conn(), operator.user)

      options = filter_options(audit_log(conn, independent.organisation))
      assert "Offer withdrawn" in options
      refute "Offered to an operator" in options
      refute "Operator left" in options
      refute "Organisation accepted as a client" in options

      refute "Organisation accepted as a client" in filter_options(
               audit_log(operator_conn, operator.organisation)
             )

      Flags.put_transfers(true)
      options = filter_options(audit_log(conn, independent.organisation))
      assert "Offer withdrawn" in options
      assert "Offered to an operator" in options
      assert "Operator left" in options

      assert "Organisation accepted as a client" in filter_options(
               audit_log(operator_conn, operator.organisation)
             )
    end

    test "entries made before still read in their words", %{conn: conn} do
      operator = operator_fixture()
      %{scope: owner, user: user, organisation: organisation} = sign_up_fixture()

      Flags.put_transfers(true)
      {:ok, _} = Transfers.offer_to_operator(owner, operator.organisation.slug)
      {:ok, client} = Transfers.accept_client(operator.scope, organisation.id)
      {:ok, _} = Transfers.leave(scope_in(user, client), operator.organisation.name)
      Flags.put_transfers(false)

      view = audit_log(log_in_user(conn, user), client)

      offered = entry(client, :"organisation.transfer")

      accepted = entry(client, :"client.accept")

      assert text(view, "#entry-#{accepted.id}-action") =~
               "#{operator.organisation.name} became its operator, accepted by an owner of"

      assert text(view, "#entry-#{offered.id}-action") =~
               "Offered the organisation to an operator"

      left = entry(client, :"organisation.leave_operator")

      assert text(view, "#entry-#{left.id}-action") =~
               "Left #{operator.organisation.name}: it has no operator now"

      view = audit_log(log_in_user(build_conn(), operator.user), operator.organisation)
      accepted = entry(operator.organisation, :"client.accept")
      assert text(view, "#entry-#{accepted.id}-action") =~ "Accepted #{client.name} as a client"
      left = entry(operator.organisation, :"organisation.leave_operator")
      assert text(view, "#entry-#{left.id}-action") =~ "#{client.name} left as a client"
    end
  end
end

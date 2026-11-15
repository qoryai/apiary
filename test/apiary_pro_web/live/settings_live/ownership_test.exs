defmodule ApiaryProWeb.SettingsLive.OwnershipTest do
  @moduledoc """
  The Ownership section of an organisation's settings: a client's operator, and the
  arbiter's offer to an admin, told on every page and accepted here.
  """
  # Not async: the features are the node's, and an operator is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # The lapse of the arbiter's offer (`organisation.withdraw_transfer`) is found here, for
  # this process and those it starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.Transfers
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryProWeb.Trail

  @moduletag with_features: Features.all()

  # An operator, its client Acme with its owner, and an admin of Acme; the client's owner
  # logged in.
  defp client_with_admin(%{conn: conn}) do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    admin = member_fixture(client.owner.scope, :admin)

    %{
      conn: log_in_user(conn, client.owner.user),
      operator: operator,
      client: client,
      admin: admin
    }
  end

  defp settings(organisation), do: ~p"/#{organisation}/settings"
  defp ownership(organisation), do: ~p"/#{organisation}/settings/ownership"

  describe "a client and its operator" do
    setup :client_with_admin

    test "its owners are listed as any organisation's, and its operator named", ctx do
      client = ctx.client.organisation
      {:ok, lv, _html} = live(ctx.conn, settings(client))

      assert has_element?(
               lv,
               "#owner-#{ctx.client.owner.membership.id}",
               ctx.client.owner.user.email
             )

      # The settings' list beside the section: the Ownership entry leads to the operator.
      assert has_element?(lv, "#settings-tab-organisation[aria-current='page']")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#settings-tab-ownership") |> render_click()

      assert to == ownership(client)

      {:ok, lv, _html} = live(ctx.conn, ownership(client))

      # The edition's section is in the organisation's list, under the organisation's sidebar.
      assert has_element?(lv, "#settings-tabs #settings-tab-ownership[aria-current='page']")
      # The settings' sections are the frame's second column, not a list in the page.
      assert has_element?(lv, "#shell-content #settings-tabs #settings-tab-ownership")
      refute has_element?(lv, "#main #settings-tabs")
      assert has_element?(lv, "aside#sidebar[aria-label='Organisation']")
      # The sidebar's Settings is current as the parent of the second column's section.
      assert has_element?(lv, ".q-sidebar-foot #nav-organisation[aria-current='true']")
      # The frame writes the level and the section; the section's title is the page's one
      # h1, and the browser's title names the section, the level and the organisation.
      assert Trail.crumbs(lv) == ["Organisation settings", "Ownership"]
      assert has_element?(lv, "#breadcrumb-section[aria-current=page]", "Ownership")
      assert has_element?(lv, "h1#settings-section-title", "Ownership")

      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#main h1")
             |> Enum.count() == 1

      assert page_title(lv) ==
               "Ownership · Organisation settings · #{client.name} · Qory Apiary"

      assert has_element?(lv, "#operator-name", ctx.operator.organisation.name)
      assert has_element?(lv, "#operator", "to support its harness, and change nothing")
      # A client's section says whose harness it runs, and no offers where it has none.
      assert has_element?(lv, ".q-settings-head-sub", "Whose harness this organisation runs.")
      refute has_element?(lv, ".q-settings-head-sub", "offers")
      # With no offer pending, there is no Ownership part.
      refute has_element?(lv, "#ownership")
    end

    test "every one of its people sees its operator, a member too", ctx do
      member = client_member_fixture(ctx.client, :member)
      conn = log_in_user(build_conn(), member.user)
      operator = ctx.operator.organisation.name

      # A member takes no action there, yet the list leads to it: it names the operator.
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert has_element?(lv, "#operator-name", operator)

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client.organisation}/settings/people")
      assert has_element?(lv, "#operated-by", "Operated by #{operator}")
    end

    test "the operator's people read the page, and are told they change nothing", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))

      assert has_element?(
               lv,
               "#operator-reader",
               "as a person of #{ctx.operator.organisation.name}"
             )

      assert has_element?(lv, "#settings-tab-ownership")
      refute has_element?(lv, "#organisation-form button[type=submit]")
    end
  end

  describe "the arbiter's offer in a client whose owner is suspended" do
    setup ctx do
      ctx = client_with_admin(ctx)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, ctx.client.owner.user.id)
      Map.put(ctx, :arbiter, arbiter)
    end

    test "the admin it is offered to reads it with its reason, accepts, and is an owner; the client stays its operator's",
         ctx do
      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      refute has_element?(lv, "#ownership-offer-notice")
      # A client's people read its operator there.
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      # The offer reaches the admin's open page, and leads to the Ownership section.
      assert has_element?(
               lv,
               "#ownership-offer-notice",
               "Support offers you the ownership of Acme"
             )

      assert has_element?(lv, "#settings-tab-ownership")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#ownership-offer-notice a") |> render_click()

      assert to == ownership(ctx.client.organisation)

      # Another page of the organisation says it too.
      {:ok, members, _html} = live(conn, ~p"/#{ctx.client.organisation}/settings/people")
      assert has_element?(members, "#ownership-offer-notice")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert render(lv) =~ "Support offers you the ownership of Acme."
      assert has_element?(lv, "#ownership-offer-reason", "The owner is away.")
      # The page's own notice is the offer: the top one is not said twice.
      refute has_element?(lv, "#ownership-offer-notice")

      {:ok, lv, html} =
        lv |> element("#accept-ownership") |> render_click() |> follow_redirect(conn)

      assert html =~ "You are the owner of Acme now."
      refute has_element?(lv, "#ownership-offer-notice")
      assert has_element?(lv, "#owner-#{ctx.admin.membership.id}", ctx.admin.user.email)

      assert Repo.get!(Membership, ctx.admin.membership.id).level == :owner

      assert Repo.get!(Tenant, ctx.client.organisation.id).operator_id ==
               ctx.operator.organisation.id

      assert Transfers.pending(ctx.admin.scope) == nil
    end

    test "it is not withdrawn here, and another of its people sees no controls", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      other = member_fixture(ctx.admin.scope, :member)
      conn = log_in_user(build_conn(), other.user)

      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      assert has_element?(lv, "#settings-tab-ownership")
      refute has_element?(lv, "#ownership-offer-notice")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      refute has_element?(lv, "#ownership")
      refute has_element?(lv, "#ownership-offer")
      assert %{arbitrated: true} = Transfers.pending(ctx.admin.scope)
    end

    test "the admin is not offered Accept when it would be refused, and is told why", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(ctx.arbiter, ctx.client.organisation.id)

      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert has_element?(lv, "#ownership-offer")
      refute has_element?(lv, "#accept-ownership")
      assert has_element?(lv, "#ownership-offer-waits", "once it is activated")
    end

    test "a withdrawn offer is not accepted, and the page says so", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))

      # The owner may act again: the offer lapses.
      {:ok, _} = ApiaryPro.Suspensions.activate_account(ctx.arbiter, ctx.client.owner.user.id)

      html = render_click(lv, "accept_transfer", %{})
      assert html =~ "No ownership is offered to you here any more"
      assert Repo.get!(Membership, ctx.admin.membership.id).level == :admin
    end
  end

  describe "the arbiter's offer in an organisation with no operator" do
    test "the recipient made a member still reads the offer, and Accept shows why the acceptance fails",
         %{conn: conn} do
      signed_up = sign_up_fixture(%{organisation_name: "Initech"})
      admin = member_fixture(signed_up.scope, :admin)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, signed_up.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          arbiter,
          signed_up.organisation.id,
          admin.membership.id,
          "The owner is away."
        )

      Repo.update!(Ecto.Changeset.change(admin.membership, level: :member))

      {:ok, lv, _html} = live(log_in_user(conn, admin.user), ownership(signed_up.organisation))
      assert has_element?(lv, "#ownership-offer")
      assert has_element?(lv, "#accept-ownership")

      html = render_click(lv, "accept_transfer", %{})
      assert html =~ "Only the admin of Initech it is offered to accepts its ownership."
      assert Repo.get!(Membership, admin.membership.id).level == :member
    end

    test "the admin reads the offer, its reason and Accept, in a section about offers only",
         %{conn: conn} do
      signed_up = sign_up_fixture(%{organisation_name: "Initech"})
      admin = member_fixture(signed_up.scope, :admin)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, signed_up.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          arbiter,
          signed_up.organisation.id,
          admin.membership.id,
          "The owner is away."
        )

      conn = log_in_user(conn, admin.user)
      {:ok, lv, _html} = live(conn, ownership(signed_up.organisation))

      assert has_element?(
               lv,
               ".q-settings-head-sub",
               "Offers of the ownership of this organisation."
             )

      refute has_element?(lv, ".q-settings-head-sub", "harness")
      refute has_element?(lv, "#operator")

      # The offer, its reason, then Accept, one under the other in the notice.
      assert has_element?(
               lv,
               "[role=note] #ownership-offer p",
               "offers you the ownership of Initech"
             )

      assert has_element?(lv, "#ownership-offer #ownership-offer-reason", "The owner is away.")
      assert has_element?(lv, "#ownership-offer button#accept-ownership", "Accept ownership")
    end
  end
end

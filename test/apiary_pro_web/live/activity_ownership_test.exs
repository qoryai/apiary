defmodule ApiaryProWeb.ActivityOwnershipTest do
  # The audit log on the edition's suspensions, transfers and features: each has its words,
  # and the instance's filter never shows an action by its code name. A member's
  # suspension, and an owner's filter, are the core's (`ApiaryWeb.ActivityLiveTest`).
  use ApiaryWeb.ConnCase, async: true

  # The lapse of the arbiter's offer (`organisation.withdraw_transfer`) is found here, for
  # this process and those it starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.Features
  alias ApiaryPro.{Suspensions, Transfers}

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  defp open(conn, organisation) do
    {:ok, view, _html} = live(conn, "/#{organisation.slug}/audit-log")
    render_async(view)
    view
  end

  defp entry(organisation, action) do
    Apiary.Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id and e.action == ^Atom.to_string(action),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  # Nobody takes features away from a workspace any more, but the trail keeps what was
  # done: an entry of it still reads with its words, and the filter does not offer it.
  test "an old entry of a workspace's features still has its words", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()

    narrowed =
      Apiary.Repo.insert!(%Apiary.Audit.Entry{
        actor_kind: :person,
        actor_id: user.id,
        action: "workspace.narrow_features",
        subject_kind: "workspace",
        subject_id: workspace.id,
        organisation_id: organisation.id,
        workspace_id: workspace.id,
        before: %{"features" => ["observability", "security"]},
        after: %{"features" => ["observability"]}
      })

    view = open(log_in_user(conn, user), organisation)

    assert text(view, "#entry-#{narrowed.id}-action") =~ "Changed the workspace's features"
    assert text(view, "#entry-#{narrowed.id}-change") =~ "Security policy"
    assert text(view, "#entry-#{narrowed.id}-subject") =~ workspace.name

    options = view |> element("#filter-action-form") |> render()
    refute options =~ "workspace.narrow_features"
    refute options =~ "Workspace's features changed"
  end

  test "the arbiter's offer shows its reason; an account's suspension names the account", %{
    conn: conn
  } do
    %{organisation: organisation, user: owner, scope: scope} = sign_up_fixture()
    %{membership: admin_membership} = member_fixture(scope, :admin)
    admin = suite_instance_admin()
    {:ok, _} = Suspensions.suspend_account(admin.instance_scope, owner.id)

    {:ok, _} =
      Transfers.arbitrate(
        admin.instance_scope,
        organisation.id,
        admin_membership.id,
        "The owner is away for a year."
      )

    # The instance admin reads the organisation's trail as the instance's reader.
    admin_conn = log_in_user(conn, admin.user)
    view = open(admin_conn, organisation)
    arbitrated = entry(organisation, :"instance.transfer")
    assert text(view, "#entry-#{arbitrated.id}-change") =~ "The owner is away for a year."

    instance_organisation = admin.instance_scope.organisation
    view = open(admin_conn, instance_organisation)
    suspended = entry(instance_organisation, :"instance.suspend_account")
    assert text(view, "#entry-#{suspended.id}-action") =~ "Suspended an account"
    assert text(view, "#entry-#{suspended.id}-subject") =~ owner.email
  end

  test "no action in the filter is shown by its code name", %{conn: conn} do
    admin = suite_instance_admin()
    view = open(log_in_user(conn, admin.user), admin.instance_scope.organisation)

    options =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-action-form li")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert options != []

    for option <- options do
      refute option =~ ~r/^[a-z_]+\.[a-z_]+$/, "#{option} is a code name"
    end
  end
end

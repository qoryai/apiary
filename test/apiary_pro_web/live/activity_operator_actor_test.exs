defmodule ApiaryProWeb.ActivityOperatorActorTest do
  # Who made an entry in an operated workspace, on the organisation's Activity page, while
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on: a person who acted there through
  # the workspace's operator, beside the operator's name (`ApiaryPro.Edition`'s
  # `audit_details/3`, `ApiaryProWeb.Edition`'s `activity_actor/2`); anyone else as the
  # core shows them. With the flag off, as the core shows them. The flag is set per process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Nodes, Organisations, Repo, Retention}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(true)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    operated = operated_fixture(operator.scope, "Acme")
    %{operator: operator, operator_name: name, operated: operated}
  end

  defp entry(organisation, action) do
    Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id and e.action == ^Atom.to_string(action),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp actor(user, organisation, entry) do
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), "/#{organisation.slug}/audit-log")
    render_async(lv)

    lv
    |> element("#entry-#{entry.id}-actor")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".q-cut, .q-faint")
    |> Enum.map_join(" ", &(&1 |> LazyHTML.text() |> String.trim()))
  end

  # `user` in the operator at `operator_level` and in the operated organisation at
  # `organisation_level`.
  defp in_both(ctx, operator_level, organisation_level) do
    %{user: user} = member_fixture(ctx.operator.scope, operator_level)
    %{membership: joined} = join_fixture(ctx.operated.owner.scope, user)

    if organisation_level != :member,
      do:
        {:ok, _} =
          Organisations.set_member_level(ctx.operated.owner.scope, joined.id, organisation_level)

    user
  end

  # The retention of the operated workspace set to `days` by the scope's person, and its
  # entry.
  defp set_retention(ctx, scope, days) do
    {:ok, _workspace} = Retention.update_retention(scope, %{events_retention_days: days})
    entry(ctx.operated.organisation, :"retention.edit")
  end

  describe "while the flag is on" do
    test "an operator person's entry names the operator beside them", ctx do
      made = set_retention(ctx, ctx.operated.scope, 7)
      assert made.details["via_operator_id"] == ctx.operator.organisation.id

      email = ctx.operator.user.email
      expected = "#{email} of #{ctx.operator_name}"

      assert actor(ctx.operated.owner.user, ctx.operated.organisation, made) == expected
    end

    test "an entry of the organisation's owner, and the operator's trail, are as the core shows them",
         ctx do
      # The organisation's owner renames the workspace: no operator beside them.
      {:ok, _} =
        Apiary.Organisations.update_workspace(ctx.operated.owner.scope, %{"name" => "Platform"})

      renamed = entry(ctx.operated.organisation, :"workspace.rename")
      refute Map.has_key?(renamed.details || %{}, "via_operator_id")

      assert actor(ctx.operated.owner.user, ctx.operated.organisation, renamed) ==
               "#{ctx.operated.owner.user.email} you"

      # In the operator itself, its owner acts as anywhere.
      {:ok, _} = Nodes.create_node(ctx.operator.scope, %{kind: "node", name: "home-1"})
      home = entry(ctx.operator.organisation, :"node.create")
      refute Map.has_key?(home.details || %{}, "via_operator_id")

      assert actor(ctx.operator.user, ctx.operator.organisation, home) ==
               "#{ctx.operator.user.email} you"
    end
  end

  describe "someone in both organisations" do
    # Their entry in the operated workspace: its retention, which the operator's owners and
    # admins set there, for an admin of the operator; a new name of the workspace, which the
    # operator does not change, for anyone else.
    defp made_in_workspace(ctx, user, made \\ :rename) do
      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      made =
        case made do
          :retention ->
            set_retention(ctx, scope, 14)

          :rename ->
            {:ok, _} =
              Organisations.update_workspace(scope, %{
                "name" => "Renamed #{System.unique_integer([:positive])}"
              })

            entry(ctx.operated.organisation, :"workspace.rename")
        end

      made.details || %{}
    end

    test "an admin of the operator who is a member of the organisation is named with the operator",
         ctx do
      user = in_both(ctx, :admin, :member)
      operator_id = ctx.operator.organisation.id

      assert %{"via_operator_id" => ^operator_id} = made_in_workspace(ctx, user, :retention)
    end

    test "equal levels in both: not named with the operator", ctx do
      user = in_both(ctx, :admin, :admin)
      refute Map.has_key?(made_in_workspace(ctx, user), "via_operator_id")
    end

    test "a member of the operator who is an admin of the organisation: not named with the operator",
         ctx do
      user = in_both(ctx, :member, :admin)
      refute Map.has_key?(made_in_workspace(ctx, user), "via_operator_id")
    end
  end

  describe "with the flag off" do
    test "an entry made while it was on reads as the core shows it", ctx do
      made = set_retention(ctx, ctx.operated.scope, 21)
      Flags.put_operator_infrastructure(false)

      assert actor(ctx.operated.owner.user, ctx.operated.organisation, made) ==
               ctx.operator.user.email
    end

    test "nothing is added to an entry", ctx do
      Flags.put_operator_infrastructure(false)

      {:ok, _} =
        Apiary.Organisations.update_workspace(ctx.operated.owner.scope, %{"name" => "Platform"})

      renamed = entry(ctx.operated.organisation, :"workspace.rename")
      refute Map.has_key?(renamed.details || %{}, "via_operator_id")

      assert ApiaryPro.Edition.audit_details(
               ctx.operated.scope,
               ctx.operated.organisation.id,
               %{}
             ) == %{}
    end
  end
end

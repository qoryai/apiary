defmodule ApiaryPro.FeaturePartsTest do
  # The parts of a feature a person is not shown (`ApiaryPro.Features.hidden/1`), the
  # run's Terminal, `:"observability.terminal"`, and the grants that hide them
  # (`ApiaryPro.Grants`): while `ApiaryPro.Flags.feature_visibility?/0` is on, a part is
  # shown wherever its feature is, but where a row of the organisation hides it, and by
  # who asks; with it off, no part is hidden and no grant names one.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Access, Features, Organisations, Repo}
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant
  alias ApiaryProWeb.ActivityDescriber

  @moduletag with_features: Features.all()

  @terminal :"observability.terminal"

  setup do
    Flags.put_feature_visibility(true)
    %{instance_scope: admin, user: admin_user} = suite_instance_admin()
    %{admin: admin, admin_user: admin_user}
  end

  defp fresh(user, organisation, workspace \\ nil), do: scope_in(user, organisation, workspace)

  # What `scope` may do with a run's log in its workspace, as the core asks it.
  defp log?(scope), do: Access.authorize(scope, :"run.read_log", scope.workspace)

  # An operator shown Runs, its Terminal tab and the security policy, and an organisation
  # whose workspace Main it operates, which follows the instance.
  defp operated(admin) do
    operator = operator_fixture()

    assert {:ok, _} =
             Grants.set_organisation(admin, operator.organisation.id, [
               "observability",
               "security",
               "observability.terminal"
             ])

    %{operator: operator, operated: operated_fixture(operator.scope, "Acme")}
  end

  # The organisation's features shown on its page, but the run's Terminal.
  defp hide_terminal(admin, organisation) do
    Grants.set_organisation(admin, organisation.id, Grants.shown(organisation) -- [@terminal])
  end

  defp rows(organisation_id) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id == ^organisation_id,
        order_by: g.feature,
        select: {g.feature, g.granted}
    )
  end

  describe "an organisation with no operator" do
    setup do: sign_up_fixture()

    test "is shown the part by default, as everyone was before", %{user: user} = ctx do
      scope = fresh(user, ctx.organisation, ctx.workspace)

      refute @terminal in scope.hidden
      assert Features.visible?(scope, @terminal)
      assert :ok = log?(scope)
      assert @terminal in Grants.shown(ctx.organisation)
      assert Grants.parts_kept(ctx.organisation) == [@terminal]
    end

    test "is hidden the part by a row, and shown it again without one", ctx do
      shown = Grants.shown(ctx.organisation) -- [@terminal]
      assert {:ok, _} = Grants.set_organisation(ctx.admin, ctx.organisation.id, shown)

      assert {@terminal, false} in rows(ctx.organisation.id)
      assert Grants.parts_kept(ctx.organisation) == []

      scope = fresh(ctx.user, ctx.organisation, ctx.workspace)
      assert @terminal in scope.hidden
      refute :observability in scope.hidden
      refute Features.visible?(scope, @terminal)
      assert Features.visible?(scope, :observability)
      assert {:error, :not_found} = log?(scope)
      assert :ok = Access.authorize(scope, :"run.read", ctx.workspace)

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.organisation.id, shown ++ [@terminal])

      refute {@terminal, false} in rows(ctx.organisation.id)
      scope = fresh(ctx.user, ctx.organisation, ctx.workspace)
      refute @terminal in scope.hidden
      assert :ok = log?(scope)
    end

    test "is hidden the part with its feature, with no row of the part", ctx do
      # Runs hidden, the part's box kept.
      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.organisation.id, [
                 "observability.terminal"
               ])

      refute {@terminal, false} in rows(ctx.organisation.id)
      assert {:observability, false} in rows(ctx.organisation.id)
      scope = fresh(ctx.user, ctx.organisation, ctx.workspace)
      assert :observability in scope.hidden
      refute Features.visible?(scope, @terminal)
      assert {:error, :not_found} = log?(scope)
    end

    test "with the switch off, is hidden no part whatever the rows, and no grant names one",
         ctx do
      shown = Grants.shown(ctx.organisation) -- [@terminal]
      assert {:ok, _} = Grants.set_organisation(ctx.admin, ctx.organisation.id, shown)
      assert @terminal in fresh(ctx.user, ctx.organisation, ctx.workspace).hidden

      Flags.put_feature_visibility(false)

      scope = fresh(ctx.user, ctx.organisation, ctx.workspace)
      refute @terminal in scope.hidden
      assert :ok = log?(scope)

      refute @terminal in Grants.shown(ctx.organisation)
      assert Grants.parts_kept(ctx.organisation) == []

      assert {:error, :above} =
               Grants.set_organisation(ctx.admin, ctx.organisation.id, [
                 "observability",
                 "observability.terminal"
               ])

      # A save with the switch off leaves the part's row as it is.
      assert {:ok, _} = Grants.set_organisation(ctx.admin, ctx.organisation.id, shown)
      assert {@terminal, false} in rows(ctx.organisation.id)
    end

    test "a change of the part alone is recorded, marked shown, and tells its people", ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(ctx.user.id))
      shown = Grants.shown(ctx.organisation)

      assert {:ok, _} = Grants.set_organisation(ctx.admin, ctx.organisation.id, shown)
      refute_received {:membership_changed, _}

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.organisation.id, shown -- [@terminal])

      organisation_id = ctx.organisation.id
      assert_received {:membership_changed, %{organisation_id: ^organisation_id}}

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation_id and
                       e.action == "instance.grant_features"
               )

      # Each part follows its feature.
      assert ["observability", "observability.terminal" | _] = entry.before["features"]
      assert entry.after["features"] == entry.before["features"] -- ["observability.terminal"]
      assert entry.details["shown"] == true

      # The Activity page names the part by the name its box has.
      said =
        :"instance.grant_features"
        |> ActivityDescriber.change(entry.before, entry.after, %{})
        |> ApiaryWeb.RichText.plain_text(%{})

      assert said =~ ~r/^Runs, Terminal tab, Security policy.* → Runs, Security policy/
    end
  end

  describe "in a workspace an operator operates" do
    setup ctx, do: operated(ctx.admin)

    test "a part the operator is hidden is not hidden from the people of the organisation operated",
         ctx do
      %{operator: operator, operated: operated} = ctx

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, operator.organisation.id, [
                 "observability",
                 "security"
               ])

      assert @terminal in fresh(operator.user, operator.organisation).hidden

      owner = fresh(operated.owner.user, operated.organisation, operated.workspace)
      refute @terminal in owner.hidden
      assert :ok = log?(owner)
      assert @terminal in Grants.shown(operated.organisation)
    end

    test "a part the organisation is hidden is hidden from its people and from the operator's people there",
         ctx do
      %{operator: operator, operated: operated} = ctx

      assert {:ok, _} = hide_terminal(ctx.admin, operated.organisation)
      assert {@terminal, false} in rows(operated.organisation.id)

      owner = fresh(operated.owner.user, operated.organisation, operated.workspace)
      assert @terminal in owner.hidden
      assert {:error, :not_found} = log?(owner)

      # The operator's people, in the workspace the operator operates, are shown what the
      # organisation is: never more.
      theirs = fresh(operator.user, operated.organisation, operated.workspace)
      assert {:operator, _via} = theirs.reach
      assert @terminal in theirs.hidden
      assert {:error, :not_found} = log?(theirs)

      assert {:ok, _} =
               Grants.set_organisation(
                 ctx.admin,
                 operated.organisation.id,
                 Grants.shown(operated.organisation)
               )

      theirs = fresh(operator.user, operated.organisation, operated.workspace)
      refute @terminal in theirs.hidden
      assert :ok = log?(theirs)
    end

    test "with the switch off, no part is hidden there", ctx do
      %{operator: operator, operated: operated} = ctx

      assert {:ok, _} = hide_terminal(ctx.admin, operated.organisation)
      Flags.put_feature_visibility(false)

      for user <- [operated.owner.user, operator.user] do
        scope = fresh(user, operated.organisation, operated.workspace)
        refute @terminal in scope.hidden
        assert :ok = log?(scope)
      end
    end

    test "a change of the organisation's part tells its people and the operator's people",
         ctx do
      %{operator: operator, operated: operated} = ctx

      for user <- [operator.user, operated.owner.user],
          do: Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))

      assert {:ok, _} = hide_terminal(ctx.admin, operated.organisation)

      operated_id = operated.organisation.id
      operator_id = operator.organisation.id
      assert_received {:membership_changed, %{organisation_id: ^operated_id}}
      assert_received {:membership_changed, %{organisation_id: ^operator_id}}

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^operated_id and e.action == "instance.grant_features"
               )

      assert "observability.terminal" in entry.before["features"]
      assert entry.after["features"] == entry.before["features"] -- ["observability.terminal"]
    end
  end

  describe "an instance admin who reaches an organisation through the instance" do
    test "is hidden no part where the organisation is", ctx do
      %{user: owner, organisation: organisation, workspace: workspace} = sign_up_fixture()
      shown = Grants.shown(organisation) -- [@terminal]
      assert {:ok, _} = Grants.set_organisation(ctx.admin, organisation.id, shown)

      scope = fresh(ctx.admin_user, organisation, workspace)
      assert scope.reach == :instance
      assert scope.hidden == []
      assert :ok = log?(scope)

      assert @terminal in fresh(owner, organisation, workspace).hidden
    end
  end

  test "a change of kind keeps the rows that hide a part", ctx do
    %{organisation: organisation} = sign_up_fixture()
    shown = Grants.shown(organisation) -- [@terminal]
    assert {:ok, _} = Grants.set_organisation(ctx.admin, organisation.id, shown)

    assert {:ok, _} = Grants.written_out(organisation, :operator, features: [:observability])
    assert {@terminal, false} in rows(organisation.id)
    assert {:observability, true} in rows(organisation.id)
  end
end

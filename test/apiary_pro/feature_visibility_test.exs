defmodule ApiaryPro.FeatureVisibilityTest do
  # What a person is not shown in an organisation (`ApiaryPro.Features.hidden/1`, which the
  # core asks through `c:Apiary.Edition.hidden/1`): by place, as an organisation is shown
  # its features, and, while `ApiaryPro.Flags.feature_visibility?/0` is on, by who asks as
  # well. Each row is asked with the flag off and on, for this process and those it starts
  # (`ApiaryPro.Flags.put_feature_visibility/1`).
  use Apiary.DataCase, async: true

  import Ecto.Query

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  # What the scope's person is not shown, as the core keeps it on a scope.
  defp hidden(scope), do: Features.hidden_of(ApiaryPro.Features.hidden(scope))

  defp with_flag(on?, fun) do
    Flags.put_feature_visibility(on?)
    fun.()
  end

  # An operator shown Runs and the security policy, and not the organisation's policy; its
  # client shown Runs alone, so the client is not shown the security policy, and not the
  # organisation's policy, which its operator is not shown either.
  defp chain do
    %{instance_scope: admin} = suite_instance_admin()
    operator = operator_fixture()

    assert {:ok, _} =
             Grants.set_organisation(admin, operator.organisation.id, [
               "observability",
               "security"
             ])

    client = client_fixture(operator.scope, "Acme")
    assert {:ok, _} = Grants.set_client(operator.scope, client.organisation.id, ["observability"])

    %{admin: admin, operator: operator, client: client}
  end

  # The scope of `user` in `organisation` (and `workspace`), loaded again from the database.
  defp fresh(user, organisation, workspace \\ nil), do: scope_in(user, organisation, workspace)

  describe "by place, with the flag off and on" do
    for on? <- [false, true] do
      @on on?

      test "the instance organisation hides nothing (flag #{@on})" do
        with_flag(@on, fn ->
          %{instance_scope: scope} = suite_instance_admin()
          assert hidden(scope) == []
          assert scope.hidden == []
        end)
      end

      test "an organisation with no operator hides what an instance admin took away (flag #{@on})" do
        with_flag(@on, fn ->
          %{instance_scope: admin} = suite_instance_admin()
          %{user: user, organisation: organisation} = sign_up_fixture()

          assert hidden(fresh(user, organisation)) == []

          assert {:ok, _} = Grants.set_organisation(admin, organisation.id, ["observability"])

          # With the switch on, the form leaves the run's Terminal out too, so it is
          # hidden with the rest (ApiaryPro.FeaturePartsTest).
          taken = Features.enabled() -- [:observability]
          taken = if @on, do: taken ++ [:"observability.terminal"], else: taken

          scope = fresh(user, organisation)
          assert hidden(scope) == taken
          assert scope.hidden == taken
        end)
      end

      test "an operator's people, in the operator, are not shown what it is not (flag #{@on})" do
        with_flag(@on, fn ->
          %{operator: operator} = chain()
          scope = fresh(operator.user, operator.organisation)

          assert :organisation_policy in scope.hidden
          refute :security in scope.hidden
          refute :observability in scope.hidden
          refute :managed_organisations in scope.hidden
        end)
      end

      test "a client's people are not shown what the client is not, nor what its operator is not (flag #{@on})" do
        with_flag(@on, fn ->
          %{client: client} = chain()
          scope = fresh(client.owner.user, client.organisation, client.workspace)

          # Hidden from the client.
          assert :security in scope.hidden
          # Hidden from its operator, and never shown to a client.
          assert :organisation_policy in scope.hidden
          assert :managed_organisations in scope.hidden
          refute :observability in scope.hidden
        end)
      end
    end
  end

  describe "the operator's people in a client" do
    setup do: chain()

    test "see the client's set with the flag off", %{client: client, operator: operator} do
      with_flag(false, fn ->
        scope = fresh(operator.user, client.organisation, client.workspace)
        assert {:operator, _via} = scope.reach

        owner = fresh(client.owner.user, client.organisation, client.workspace)
        assert scope.hidden == owner.hidden
        assert :security in scope.hidden
      end)
    end

    test "see what the operator is shown with the flag on", %{client: client, operator: operator} do
      with_flag(true, fn ->
        scope = fresh(operator.user, client.organisation, client.workspace)
        assert {:operator, _via} = scope.reach

        assert scope.hidden == fresh(operator.user, operator.organisation).hidden
        refute :security in scope.hidden
        assert :organisation_policy in scope.hidden

        # The client's people still are not shown it.
        assert :security in fresh(client.owner.user, client.organisation, client.workspace).hidden
      end)
    end

    test "with the flag on, read the client's hidden security policy and its people do not",
         %{client: client, operator: operator} do
      with_flag(true, fn ->
        scope = fresh(operator.user, client.organisation, client.workspace)
        assert :ok = Access.authorize(scope, :"security_policy.read", client.workspace)

        owner = fresh(client.owner.user, client.organisation, client.workspace)

        assert {:error, :not_found} =
                 Access.authorize(owner, :"security_policy.read", client.workspace)
      end)

      with_flag(false, fn ->
        scope = fresh(operator.user, client.organisation, client.workspace)

        assert {:error, :not_found} =
                 Access.authorize(scope, :"security_policy.read", client.workspace)
      end)
    end

    test "a person who is a member of the client too sees the operator's set where their reach is read",
         %{client: client, operator: operator} do
      with_flag(true, fn ->
        _joined = join_fixture(client.owner.scope, operator.user)

        # resolve_scope/4, as a page's path loads it, reads their reach through the
        # operator.
        scope = fresh(operator.user, client.organisation, client.workspace)
        assert {:operator, _via} = scope.reach
        assert scope.membership
        refute :security in scope.hidden

        # load_scope/2 puts their membership in the client without the edition's reach:
        # what the client is not shown is hidden from them there too, more hidden, never
        # less.
        loaded = Organisations.load_scope(Scope.for_user(operator.user), client.organisation.id)
        assert loaded.organisation.id == client.organisation.id
        assert loaded.reach == nil
        assert :security in loaded.hidden
        assert :organisation_policy in loaded.hidden

        # Read again, their reach through the operator is back, and with it the operator's
        # set.
        reloaded = Access.reload(loaded)
        assert {:operator, _via} = reloaded.reach
        refute :security in reloaded.hidden
      end)
    end
  end

  describe "an instance admin who reaches an organisation through the instance" do
    setup do
      %{instance_scope: admin, user: admin_user} = suite_instance_admin()
      %{user: owner, organisation: organisation, workspace: workspace} = sign_up_fixture()

      # The security policy taken away, with the features that need it.
      shown =
        Grants.shown(organisation) --
          [:security, :organisation_policy, :organisation_variables]

      assert {:ok, _} = Grants.set_organisation(admin, organisation.id, shown)

      %{admin_user: admin_user, owner: owner, organisation: organisation, workspace: workspace}
    end

    test "is not shown what the organisation is not, with the flag off", ctx do
      with_flag(false, fn ->
        scope = fresh(ctx.admin_user, ctx.organisation, ctx.workspace)
        assert scope.reach == :instance
        assert :security in scope.hidden

        assert {:error, :not_found} =
                 Access.authorize(scope, :"security_policy.read", ctx.workspace)
      end)
    end

    test "sees everything with the flag on, and reads a hidden policy without changing it",
         ctx do
      with_flag(true, fn ->
        scope = fresh(ctx.admin_user, ctx.organisation, ctx.workspace)
        assert scope.reach == :instance
        assert scope.hidden == []

        assert :ok = Access.authorize(scope, :"security_policy.read", ctx.workspace)

        assert {:error, :forbidden} =
                 Access.authorize(scope, :"security_policy.edit", ctx.workspace)

        assert :ok = Access.authorize(scope, :"organisation_policy.read", ctx.organisation)

        assert {:error, :forbidden} =
                 Access.authorize(scope, :"organisation_policy.edit", ctx.organisation)

        # The organisation's people still are not shown it.
        assert :security in fresh(ctx.owner, ctx.organisation, ctx.workspace).hidden
      end)
    end
  end

  describe "a feature hidden with the features it needs" do
    for on? <- [false, true] do
      @on on?

      test "hiding Runs hides the security policy and secrets (flag #{@on})" do
        with_flag(@on, fn ->
          %{user: user, organisation: organisation} = sign_up_fixture()

          Repo.insert!(%Grant{
            organisation_id: organisation.id,
            feature: :observability,
            granted: false,
            inserted_at: DateTime.utc_now()
          })

          scope = fresh(user, organisation)
          assert scope.hidden == Features.enabled()
          assert :security in scope.hidden
          assert :secrets in scope.hidden
        end)
      end
    end
  end

  # Rows no grant writes, set by hand: Runs not shown, and what needs the security policy
  # shown, two links down the needs. A list and an organisation's page say the same.
  test "a list and one organisation agree where the rows break the needs two links down" do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    %{organisation: organisation} = sign_up_fixture()

    rows = fn id, features, granted ->
      Repo.delete_all(from g in Grant, where: g.organisation_id == ^id)

      for feature <- features,
          do:
            Repo.insert!(%Grant{
              organisation_id: id,
              feature: feature,
              granted: granted,
              inserted_at: DateTime.utc_now()
            })
    end

    rows.(
      operator.organisation.id,
      [:security, :organisation_policy, :managed_organisations],
      true
    )

    rows.(client.organisation.id, [:security, :organisation_policy], true)
    rows.(organisation.id, [:observability], false)

    organisations = [operator.organisation, client.organisation, organisation]
    listed = ApiaryPro.Features.of_all(organisations)

    for o <- organisations do
      assert listed[o.id] == ApiaryPro.Features.of(o)
      assert listed[o.id] == []
    end
  end

  test "an answer that does not depend on the workspace" do
    %{instance_scope: admin} = suite_instance_admin()
    %{scope: owner, organisation: organisation} = sign_up_fixture()
    other = workspace_fixture(organisation, "Staging")
    assert {:ok, _} = Grants.set_organisation(admin, organisation.id, ["observability"])

    for on? <- [false, true] do
      with_flag(on?, fn ->
        here = fresh(owner.user, organisation, owner.workspace)
        there = fresh(owner.user, organisation, other)
        assert here.hidden == there.hidden
        assert ApiaryPro.Features.hidden(%{here | workspace: nil}) == hidden(here)
      end)
    end
  end
end

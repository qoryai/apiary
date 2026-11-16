defmodule ApiaryPro.FeatureGrantRacesTest do
  # A write of the security policy racing the withdrawal of `security` from its
  # organisation, by an instance admin. Each side runs on a separate connection, outside
  # the SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`ApiaryPro.Grants`, `Apiary.Access.reload/2`): a withdrawal
  # locks the organisation `FOR UPDATE` first; a policy write takes the workspace's lock
  # and holds the organisation `FOR KEY SHARE` while it asks, and reads the features after
  # its locks. So a write that holds them is written, and the
  # withdrawal waits for it; a write that comes second waits, and then finds the feature
  # absent. A write never commits on a feature a withdrawal committed before it took away.
  #
  # A grant takes the organisation's row only, and renders nothing: a grant and a write of
  # the organisation's policy wait for each other on that row, and Postgres breaks no
  # deadlock between them (`deadlocks/0`).
  use ExUnit.Case, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Features, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Policy.{Error, Rule}
  alias ApiaryPro.{Grants, OrganisationPolicy}

  @moduletag needs: :security

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation of a fresh owner, and an instance admin's scope in the instance
  # organisation, whose membership is inserted as it is and goes with their account.
  setup do
    %{scope: owner} = sign_up()
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    {:ok, instance_admin} =
      Organisations.resolve_scope(Scope.for_user(admin.user), instance_organisation.slug)

    %{owner: owner, instance_admin: instance_admin}
  end

  # Every feature the organisation's page shows, but `features`.
  defp without(ctx, features) do
    shown = Grants.shown(Repo.get!(Organisation, ctx.owner.organisation.id))
    Grants.set_organisation(ctx.instance_admin, ctx.owner.organisation.id, shown -- features)
  end

  # What is left once `security` is taken away, and what needs it with it: everything
  # else a page shows.
  defp without_security,
    do: Features.closed(Enum.filter(Features.enabled(), &(&1 in Features.built())) -- [:security])

  @tag :feature_sets
  test "its organisation: the write first commits, and the withdrawal waits for it", ctx do
    {write, write_pid} = hold(fn -> allow(ctx.owner) end)
    assert {:ok, _} = write.result

    withdrawal = start(fn -> withdraw(ctx) end)
    await_blocked(withdrawal.backend, write_pid)
    commit(write)

    assert {:ok, _features} = Task.await(withdrawal.task)
    assert rule?(ctx.owner)
    refute :security in ApiaryPro.Features.of(reloaded(ctx.owner))
  end

  @tag :feature_sets
  test "its organisation: the withdrawal first, the write waits for it and finds the feature gone",
       ctx do
    {withdrawal, withdrawal_pid} = hold(fn -> withdraw(ctx) end)
    assert {:ok, _features} = withdrawal.result

    write = start(fn -> allow(ctx.owner) end)
    await_blocked(write.backend, withdrawal_pid)
    commit(withdrawal)

    assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
    refute rule?(ctx.owner)
  end

  describe "a grant and a write of the organisation's policy" do
    # The organisation has a policy that denies paste.example, rendered in its workspace
    # Main; an instance admin takes `organisation_policy` away from it while its owner
    # writes the policy. The grant holds the organisation `FOR NO KEY UPDATE`, the write
    # holds it `FOR SHARE` and then its workspaces: whichever comes second waits for the
    # first on the organisation's row. The grant writes nothing to a workspace's History.
    @describetag needs: :organisation_policy

    setup ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      :ok
    end

    test "the grant first: the write waits, and finds the feature gone", ctx do
      before = deadlocks()
      changes = history(ctx.owner)

      {grant, grant_pid} = hold(fn -> without(ctx, [:organisation_policy]) end)
      assert {:ok, _features} = grant.result

      write = start(fn -> OrganisationPolicy.deny(ctx.owner, %{host: "pastebin.example"}) end)
      await_blocked(write.backend, grant_pid)
      commit(grant)

      assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
      assert deadlocks() == before
      assert history(ctx.owner) == changes
    end

    test "the write first: the grant waits for it, and writes no History", ctx do
      before = deadlocks()

      {write, write_pid} =
        hold(fn -> OrganisationPolicy.deny(ctx.owner, %{host: "pastebin.example"}) end)

      assert {:ok, _rule} = write.result

      grant = start(fn -> without(ctx, [:organisation_policy]) end)
      await_blocked(grant.backend, write_pid)
      commit(write)

      assert {:ok, features} = Task.await(grant.task)
      refute :organisation_policy in features
      assert deadlocks() == before

      user_id = ctx.owner.user.id
      assert [%{action: "above_changed", changed_by_id: ^user_id} | _] = history(ctx.owner)

      # The version 1 of the workspace's creation is the one change by nobody.
      refute Enum.any?(
               history(ctx.owner),
               &(is_nil(&1.changed_by_id) and &1.action != "first_version")
             )
    end
  end

  defp withdraw(ctx),
    do:
      Grants.set_organisation(
        ctx.instance_admin,
        ctx.owner.organisation.id,
        without_security()
      )

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})

  defp rule?(scope),
    do:
      Repo.exists?(
        from r in Rule, where: r.workspace_id == ^scope.workspace.id and r.host == "race.example"
      )

  defp reloaded(scope), do: Repo.get!(Apiary.Organisations.Organisation, scope.organisation.id)

  # The newest page of the workspace's policy History.
  defp history(scope), do: Policy.list_changes(scope, nil, 1).items

  # Postgres's count of the deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end

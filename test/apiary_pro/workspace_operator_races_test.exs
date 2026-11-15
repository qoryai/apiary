defmodule ApiaryPro.WorkspaceOperatorRacesTest do
  # A write of an operator's person in the workspace the operator operates, racing the
  # operator's suspension. Each side runs on a connection of its
  # own, outside the SQL sandbox, so each commits and each waits on the other's locks as
  # it would in production. Not async: what these tests commit is visible to every other
  # test while they run, and they delete it again before they end.
  #
  # The rules under test (`ApiaryPro.WorkspaceOperators`, Locks; `ApiaryPro.Suspensions`):
  # a suspension locks the operator's row for update; a write in the workspace holds the
  # organisation and the operators of its workspaces `FOR SHARE`
  # (`Apiary.Access.lock_places/1`). So whichever comes second waits for the first, and
  # then sees it: a write never commits through an operator that was suspended before it.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.OperatorsFixtures, only: [operate_fixture: 2]

  alias Apiary.{Organisations, Repo, TimeLimits}
  alias Apiary.TimeLimits.TimeLimit
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Flags, Operators, Suspensions}
  alias ApiaryPro.Operators.WorkspaceOperator
  alias ApiaryPro.Tenants.Tenant
  alias Ecto.Adapters.SQL.Sandbox

  # An operator is `managed_organisations`': left out of a run without it.
  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one by an instance admin as the product makes one; an organisation
  # whose workspace Main the operator operates; an admin of the operator, Ann, whose scope is in Main, with the flag
  # on so that she sets Main's time limits; and the instance admin's scope in the
  # instance organisation, whose membership is inserted as it is and goes with their
  # account.
  setup do
    Flags.put_operator_infrastructure(true)
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    on_exit(fn -> clean_up_instance_entries(instance_organisation.id, admin.user.id) end)
    instance_admin = scope_in(admin.user, instance_organisation)

    operator = sign_up()

    {:ok, _operator} =
      Operators.change_kind(instance_admin, operator.organisation.id, :operator)

    in_operator = scope_in(operator.user, operator.organisation)
    ann = member(in_operator, :admin)

    organisation = sign_up()
    workspace = organisation.scope.workspace
    operate_fixture(workspace, operator.organisation)

    %{
      operator: operator.organisation,
      workspace: workspace,
      ann: scope_in(ann.user, organisation.organisation, workspace),
      instance_admin: instance_admin
    }
  end

  describe "the operator suspended while its person writes in the workspace" do
    test "the write first: the suspension waits, and both commit", ctx do
      {write, write_pid} = hold(fn -> write(ctx) end)
      assert {:ok, %TimeLimit{minutes: 90}} = write.result

      suspension = start(fn -> suspend(ctx) end)
      await_blocked(suspension.backend, write_pid)
      commit(write)

      assert {:ok, %Organisation{}} = Task.await(suspension.task)
      assert suspended?(ctx)
      assert limited?(ctx)
    end

    test "the suspension first: the write waits, and is refused", ctx do
      {suspension, suspension_pid} = hold(fn -> suspend(ctx) end)
      assert {:ok, %Organisation{}} = suspension.result

      write = start(fn -> write(ctx) end)
      await_blocked(write.backend, suspension_pid)
      commit(suspension)

      # Ann reaches Main through the operator no more, and has no membership in its
      # organisation: the role refuses her.
      assert {:error, :forbidden} = Task.await(write.task)
      assert suspended?(ctx)
      assert linked?(ctx)
      refute limited?(ctx)
    end
  end

  # Ann's write in Main: a time limit of its runs, which the operator's admins set there
  # while the flag is on. It holds the organisation and the operator `FOR SHARE`.
  defp write(ctx), do: TimeLimits.put_limit(ctx.ann, :workspace, "hello", 90)

  defp suspend(ctx), do: Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.id)

  defp linked?(ctx), do: Repo.get(WorkspaceOperator, ctx.workspace.id) != nil

  defp suspended?(ctx), do: Repo.get!(Tenant, ctx.operator.id).suspended_at != nil

  # Whether Main has the time limit Ann's write sets.
  defp limited?(ctx),
    do: Repo.exists?(from l in TimeLimit, where: l.workspace_id == ^ctx.workspace.id)

  defp scope_in(user, organisation, workspace \\ nil) do
    {:ok, scope} =
      Organisations.resolve_scope(
        Scope.for_user(user),
        organisation.slug,
        workspace && workspace.slug
      )

    scope
  end

  # The instance admin's entries in the instance organisation's trail, which is not
  # deleted with the race's organisations.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    # The next clean-up checks its own connection out.
    Sandbox.checkin(Repo)
  end
end

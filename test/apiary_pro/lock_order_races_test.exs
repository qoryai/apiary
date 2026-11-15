defmodule ApiaryPro.LockOrderRacesTest do
  # The acceptance of the arbiter's offer against a change paused half way: one that holds
  # the owners and has not written its entry. Each side runs on a separate connection,
  # outside the SQL sandbox; the first is held half way (`hold/1`), the second started and
  # seen waiting on it (`await_blocked/2`), then the first finishes its second half in the
  # same transaction (`continue/2`): what a deadlock needs, each side waiting
  # on the other. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test is the lock order of docs/access.md: organisation rows first, then
  # people locks (the operators of the organisation's workspaces), then workspaces,
  # memberships and accounts. Each side takes the rows it needs in that order, so the
  # second waits on the first's first row and holds nothing the first's second half needs:
  # nothing deadlocks, which the deadlock count of Postgres shows.
  use ExUnit.Case, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Grants, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Tenants.Tenant

  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one as the product makes one, and an instance admin; and an
  # organisation whose workspace Main the operator operates, with its owner and a first
  # admin.
  setup do
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

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.organisation.id),
      set: [kind: :operator]
    )

    operator_row = Organisation |> Repo.get!(operator.organisation.id) |> Tenants.put()
    {:ok, _features} = Grants.written_out(operator_row, :operator)
    in_operator = scope_in(operator.user, operator_row)

    operated = operated(in_operator)
    admin = member(operated.owner.scope, :admin)

    %{
      instance_admin: instance_admin,
      organisation: operated.organisation,
      workspace: operated.workspace,
      owner: operated.owner,
      admin: admin
    }
  end

  describe "the arbiter's offer, accepted by an admin of an operated organisation" do
    # The organisation's owner suspended, the arbiter offers its ownership to a second admin.
    setup ctx do
      recipient = member(ctx.owner.scope, :admin)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, ctx.owner.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          ctx.instance_admin,
          ctx.organisation.id,
          recipient.membership.id,
          "Races."
        )

      %{recipient: scope_in(recipient.user, ctx.organisation, ctx.workspace)}
    end

    test "against a change of a level holding the owners, its entry not yet written", ctx do
      before = deadlocks()
      admin = ctx.admin.scope

      {change, change_pid} =
        hold(fn -> level_change_first_half(admin, ctx.admin.membership) end)

      acceptance = start(fn -> Transfers.accept(ctx.recipient) end)
      await_blocked(acceptance.backend, change_pid)

      assert {:ok, _entry} = continue(change, fn -> level_change_entry(admin, change) end)
      commit(change)

      assert {:ok, %Organisation{id: organisation_id}} = Task.await(acceptance.task)
      assert organisation_id == ctx.organisation.id
      assert deadlocks() == before
    end
  end

  ## The first halves, as the product takes them, and their second halves

  # A change of a level, up to its entry: the organisation rows and the owners, then the
  # membership changed (`Apiary.Organisations.set_member_level/3`).
  defp level_change_first_half(scope, %Membership{} = membership) do
    :ok = Organisations.lock_owners(scope)
    level = if membership.level == :member, do: :admin, else: :member

    {:ok, changed} = membership |> Membership.changeset(%{level: level}) |> Repo.update()
    %{before: membership, changed: changed}
  end

  # Its entry, which names the organisation, and so holds it `FOR KEY SHARE`.
  defp level_change_entry(scope, held) do
    %{before: before, changed: changed} = held.result

    Audit.record(Repo, scope, :"member.change_level", changed, %{
      before: %{level: before.level},
      after: %{level: changed.level},
      details: %{user_id: changed.user_id}
    })
  end

  ## Helpers

  # Postgres's own count of deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  defp scope_in(user, organisation, workspace \\ nil) do
    {:ok, scope} =
      Organisations.resolve_scope(
        Scope.for_user(user),
        organisation.slug,
        workspace && workspace.slug
      )

    scope
  end

  # The instance admin's entries in the instance organisation's trail, which no
  # organisation of the race takes with it.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    # The next clean-up checks its own connection out.
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end
end

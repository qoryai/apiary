defmodule ApiaryPro.SuspensionRacesTest do
  # A write of the security policy racing a suspension that takes away the writer's right
  # to make it: of their account, of their organisation (a membership's is the core's,
  # `Apiary.SuspensionRacesTest`). Each side runs on a connection of its own, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`ApiaryPro.Suspensions`, `Apiary.Access.reload/2`): a write reads
  # the account and the organisation `FOR KEY SHARE`; a suspension locks the account or
  # the organisation `FOR UPDATE`. So a suspension that arrives while a write holds them
  # waits for it, and a write that arrives while a suspension holds them waits, and then
  # sees it: a write never commits on a right a suspension committed before it took away.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Organisations, Policy, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Membership
  alias Apiary.Policy.{Error, Rule}
  alias ApiaryPro.Suspensions
  alias Ecto.Adapters.SQL.Sandbox
  alias ApiaryPro.Tenants.Tenant

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation with an owner and a member who writes the policy, and an instance
  # admin's scope in the instance organisation. The instance admin's membership is
  # inserted as it is, and goes with their account; the entries an account's suspension
  # leaves in the instance organisation's trail are deleted when the test ends.
  setup do
    %{scope: owner} = sign_up()
    %{user: user, scope: scope} = member(owner, :member)
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    on_exit(fn -> clean_up_instance_entries(instance_organisation.id, admin.user.id) end)

    {:ok, instance_admin} =
      Organisations.resolve_scope(Scope.for_user(admin.user), instance_organisation.slug)

    %{
      owner: owner,
      writer: %{scope: scope, membership: scope.membership, user: user},
      instance_admin: instance_admin
    }
  end

  for target <- [:account, :organisation] do
    @target target

    test "the write first, then the #{target}'s suspension: the suspension waits, and the write commits",
         ctx do
      {write, write_pid} = hold(fn -> allow(ctx.writer.scope) end)
      assert {:ok, %Rule{}} = write.result

      suspension = start(fn -> suspend(@target, ctx) end)
      await_blocked(suspension.backend, write_pid)
      commit(write)

      assert {:ok, _suspended} = Task.await(suspension.task)
      assert suspended?(@target, ctx)
      assert rule?(ctx.writer)
      assert [_entry] = policy_entries(ctx.writer)
    end

    test "the #{target}'s suspension first, then the write: the write waits, and is refused",
         ctx do
      {suspension, suspension_pid} = hold(fn -> suspend(@target, ctx) end)
      assert {:ok, _suspended} = suspension.result

      write = start(fn -> allow(ctx.writer.scope) end)
      await_blocked(write.backend, suspension_pid)
      commit(suspension)

      # No membership that counts, or an organisation that is read-only: forbidden.
      assert {:error, %Error{reason: :forbidden}} = Task.await(write.task)
      assert suspended?(@target, ctx)
      refute rule?(ctx.writer)
      assert policy_entries(ctx.writer) == []
    end
  end

  describe "an invited sign-up racing the organisation's suspension" do
    # The invitation's organisation is held `FOR SHARE` before the account is made and the
    # invitation claimed, as its acceptance holds it; a suspension locks it for update. So
    # a suspension that arrives while a sign-up holds it waits, and a sign-up that arrives
    # while a suspension holds it waits, and then is refused: nobody joins a suspended
    # organisation.
    @describetag needs: :observability

    setup ctx do
      email = "user#{System.unique_integer([:positive])}@races.test"

      %{token: token} =
        Apiary.OrganisationsFixtures.invitation_fixture(ctx.owner, %{"email" => email})

      # What the race makes is remembered from the side that makes it, in a process of
      # its own.
      %{email: email, token: token, created: Process.get(Apiary.Races)}
    end

    test "the sign-up first: the suspension waits, and the person has joined", ctx do
      {sign_up, sign_up_pid} = hold(fn -> invited_sign_up(ctx) end)
      assert {:ok, %{membership: %Membership{}}} = sign_up.result

      suspension = start(fn -> suspend(:organisation, ctx) end)
      await_blocked(suspension.backend, sign_up_pid)
      commit(sign_up)

      assert {:ok, _suspended} = Task.await(suspension.task)
      assert suspended?(:organisation, ctx)
      assert joined?(ctx)
    end

    test "the suspension first: the sign-up waits, and is refused", ctx do
      {suspension, suspension_pid} = hold(fn -> suspend(:organisation, ctx) end)
      assert {:ok, _suspended} = suspension.result

      sign_up = start(fn -> invited_sign_up(ctx) end)
      await_blocked(sign_up.backend, suspension_pid)
      commit(suspension)

      assert {:error, %Ecto.Changeset{} = changeset} = Task.await(sign_up.task)
      assert {"was invited, but the invitation is no longer valid", _} = changeset.errors[:email]
      refute joined?(ctx)
      refute Repo.exists?(from u in User, where: u.email == ^ctx.email)
    end
  end

  # The invitation accepted by a sign-up, whose account is remembered for the clean-up.
  defp invited_sign_up(ctx) do
    with {:ok, %{user: user}} = result <-
           Organisations.sign_up_user(%{email: ctx.email}, ctx.token) do
      Agent.update(ctx.created, fn created ->
        %{created | users: [user.id | created.users]}
      end)

      result
    end
  end

  defp joined?(ctx) do
    Repo.exists?(
      from m in Membership,
        join: u in assoc(m, :user),
        where: m.organisation_id == ^ctx.owner.organisation.id and u.email == ^ctx.email
    )
  end

  defp suspend(:account, ctx),
    do: Suspensions.suspend_account(ctx.instance_admin, ctx.writer.user.id)

  defp suspend(:organisation, ctx),
    do: Suspensions.suspend_organisation(ctx.instance_admin, ctx.owner.organisation.id)

  defp suspended?(:account, ctx), do: Suspensions.account_suspended?(ctx.writer.user.id)

  defp suspended?(:organisation, ctx),
    do: Repo.get!(Tenant, ctx.owner.organisation.id).suspended_at != nil

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})

  defp rule?(writer),
    do:
      Repo.exists?(
        from r in Rule,
          where: r.workspace_id == ^writer.scope.workspace.id and r.host == "race.example"
      )

  # The policy's entries in the audit trail written by the person.
  defp policy_entries(writer) do
    Repo.all(
      from e in Entry,
        where:
          e.organisation_id == ^writer.scope.organisation.id and
            e.actor_id == ^writer.user.id and like(e.action, "security_policy.%"),
        select: e.id
    )
  end

  # The instance admin's entries in the instance organisation's trail, which is not
  # deleted with the race's organisations.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    # The next clean-up checks its own connection out.
    Sandbox.checkin(Repo)
  end
end

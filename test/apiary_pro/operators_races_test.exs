defmodule ApiaryPro.OperatorsRacesTest do
  # A client created while its operator is made an organisation, or deleted. Each side
  # runs on a connection of its own, outside the SQL sandbox, so each commits and each
  # waits on the other's locks as it would in production. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  #
  # The rule under test (`ApiaryPro.Operators.create_client/3`, `change_kind/3`,
  # `Apiary.Deletion.delete_organisation/2`): creating a client locks its operator's row
  # `FOR NO KEY UPDATE`, which the count of its invitations needs, before it asks
  # `Apiary.Access`, and a change of the operator's kind and its deletion lock the row for
  # update too. So whichever comes second waits for the first, and
  # then sees it: a client is never created under an operator that became an organisation
  # or was marked for deletion, and an operator never becomes one or is marked with a
  # client it did not see.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Deletion, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Membership, Organisation}
  alias ApiaryPro.Operators
  alias ApiaryPro.Tenants.Tenant

  # An operator is `managed_organisations`': left out of a run without it.
  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, with its owner's scope in it, and an instance admin's scope in the
  # instance organisation. The instance admin's membership is inserted as it is, with no
  # entry in the instance organisation's trail, which no race test cleans up: it goes with
  # their account.
  setup do
    operator = sign_up()

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.organisation.id),
      set: [kind: :operator]
    )

    # Granted what the instance has, as an organisation made an operator is.
    {:ok, _features} =
      ApiaryPro.Grants.written_out(
        Repo.get!(Organisation, operator.organisation.id),
        :operator
      )

    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    %{
      operator: operator,
      owner: scope_in(operator.user, operator.organisation.slug),
      instance_admin: scope_in(admin.user, instance_organisation.slug)
    }
  end

  test "made an organisation first: the client waits, and is not created", ctx do
    {change, change_pid} =
      hold(fn ->
        Operators.change_kind(ctx.instance_admin, ctx.operator.organisation.id, :organisation)
      end)

    assert {:ok, %Organisation{edition: %{tenant: %Tenant{kind: :organisation}}}} = change.result

    create = start(fn -> create(ctx.owner) end)
    await_blocked(create.backend, change_pid)
    commit(change)

    assert {:error, :not_found} = Task.await(create.task)
    refute clients?(ctx.operator)
  end

  test "the client first: making the operator an organisation waits, and is refused", ctx do
    {create, create_pid} = hold(fn -> create(ctx.owner) end)
    assert {:ok, %{organisation: client}} = create.result
    remember(client)

    change =
      start(fn ->
        Operators.change_kind(ctx.instance_admin, ctx.operator.organisation.id, :organisation)
      end)

    await_blocked(change.backend, create_pid)
    commit(create)

    assert {:error, :has_clients} = Task.await(change.task)
    assert Repo.get!(Tenant, ctx.operator.organisation.id).kind == :operator
    assert clients?(ctx.operator)
  end

  test "deleted first: the client waits, and is not created", ctx do
    {deletion, deletion_pid} =
      hold(fn -> Deletion.delete_organisation(ctx.owner, ctx.operator.organisation.slug) end)

    assert {:ok, %Organisation{}} = deletion.result

    create = start(fn -> create(ctx.owner) end)
    await_blocked(create.backend, deletion_pid)
    commit(deletion)

    assert {:error, :not_found} = Task.await(create.task)
    refute clients?(ctx.operator)
  end

  test "the client first: the deletion waits, and is refused while the client is there", ctx do
    {create, create_pid} = hold(fn -> create(ctx.owner) end)
    assert {:ok, %{organisation: client}} = create.result
    remember(client)

    deletion =
      start(fn -> Deletion.delete_organisation(ctx.owner, ctx.operator.organisation.slug) end)

    await_blocked(deletion.backend, create_pid)
    commit(create)

    assert {:error, :has_clients} = Task.await(deletion.task)

    assert %Organisation{deletion_marked_at: nil} =
             Repo.get!(Organisation, ctx.operator.organisation.id)
  end

  describe "while the operator owns its clients" do
    # The rule under test (`ApiaryPro.Invitations.accepting/3`,
    # `ApiaryPro.Deletion.delete_client/3`): an acceptance of the operator's invitation
    # locks the client's row `FOR NO KEY UPDATE` before it reads whether the client has an
    # owner or an admin, and a client's deletion locks the same row before it reads whether
    # anyone has joined. So two first admins never both join, and a client is never
    # deleted with someone in it, nor joined once it is deleted.
    setup ctx do
      ApiaryPro.Flags.put_operator_infrastructure(true)
      first = sign_up()
      second = sign_up()
      {client, first_token} = create_for(ctx.owner, first.user.email)
      second_token = invite_admin_for(ctx.owner, client, second.user.email)
      %{client: client, first: {first.user, first_token}, second: {second.user, second_token}}
    end

    test "two first admins accept at once: one joins, the other's invitation is refused",
         ctx do
      {first_user, first_token} = ctx.first
      {second_user, second_token} = ctx.second

      {accept, accept_pid} =
        hold(fn -> Organisations.accept_invitation(first_user, first_token) end)

      assert {:ok, %Membership{level: :admin}} = accept.result

      other = start(fn -> Organisations.accept_invitation(second_user, second_token) end)
      await_blocked(other.backend, accept_pid)
      commit(accept)

      assert {:error, :invalid} = Task.await(other.task)
      assert levels(ctx.client) == [:admin]
    end

    test "an acceptance first: the deletion waits, and is refused", ctx do
      {first_user, first_token} = ctx.first

      {accept, accept_pid} =
        hold(fn -> Organisations.accept_invitation(first_user, first_token) end)

      assert {:ok, %Membership{}} = accept.result

      deletion =
        start(fn ->
          ApiaryPro.Deletion.delete_client(ctx.owner, ctx.client.id, ctx.client.name)
        end)

      await_blocked(deletion.backend, accept_pid)
      commit(accept)

      assert {:error, :has_people} = Task.await(deletion.task)
      assert %Organisation{deletion_marked_at: nil} = Repo.get!(Organisation, ctx.client.id)
    end

    test "the deletion first: the acceptance waits, and is refused", ctx do
      {first_user, first_token} = ctx.first

      {deletion, deletion_pid} =
        hold(fn ->
          ApiaryPro.Deletion.delete_client(ctx.owner, ctx.client.id, ctx.client.name)
        end)

      assert {:ok, %Organisation{}} = deletion.result

      accept = start(fn -> Organisations.accept_invitation(first_user, first_token) end)
      await_blocked(accept.backend, deletion_pid)
      commit(deletion)

      assert {:error, :invalid} = Task.await(accept.task)
      assert levels(ctx.client) == []
    end
  end

  describe "a renewal of a first owner's invitation whose client's trail no longer names its allowance" do
    # A client whose first owner's invitation was counted against the operator, its entry
    # gone from the client's trail: the renewal counts it against the client
    # (`Apiary.Organisations.allowance_of/1`). A write in the client holds the client's
    # row `FOR SHARE`, then the operator's, in the lock order, as the one statement of
    # `Apiary.Access.lock_places/1` takes them, here paused between the two.
    setup ctx do
      {:ok, %{organisation: client}} = create(ctx.owner)
      remember(client)
      invitation = Repo.get_by!(Invitation, organisation_id: client.id)

      Repo.delete_all(
        from e in Apiary.Audit.Entry,
          where: e.organisation_id == ^client.id and e.subject_id == ^invitation.id,
          where: fragment("? \\? 'allowance_id'", e.details)
      )

      assert {:ok, %Organisation{id: allowance_id}} = Organisations.allowance_of(invitation)
      assert allowance_id == client.id
      %{client: client, invitation: invitation}
    end

    test "it takes the client's row in its one mode at once, and nothing deadlocks", ctx do
      before = deadlocks()
      {write, write_pid} = hold(fn -> locked(ctx.client.id) end)

      renewal =
        start(fn ->
          Operators.renew_owner_invitation(
            ctx.owner,
            ctx.client.id,
            ctx.invitation.id,
            &"http://localhost/invitations/#{&1}"
          )
        end)

      # It waits at the client, holding no row the write needs next.
      await_blocked(renewal.backend, write_pid)
      assert continue(write, fn -> locked(ctx.operator.organisation.id) end)
      commit(write)

      assert {:ok, %Invitation{}} = Task.await(renewal.task)
      assert deadlocks() == before
    end
  end

  # The organisation's row held `FOR SHARE`: its id.
  defp locked(id),
    do: Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR SHARE")

  # Postgres's own count of deadlocks it broke in this database. A hint only: the count
  # is flushed to `pg_stat_database` some time after the fact, and a deadlock the core's
  # retry under a savepoint absorbs is counted only once its transaction ends. What
  # catches a deadlock is the other assertions: the result each side answers, and the
  # rows it leaves.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  defp levels(%Organisation{id: id}),
    do: Repo.all(from m in Membership, where: m.organisation_id == ^id, select: m.level)

  # A client of the operator whose first person is invited at `email`: the client and the
  # invitation's token.
  defp create_for(owner, email) do
    parent = self()

    {:ok, %{organisation: client}} =
      Operators.create_client(owner, %{"name" => name(), "email" => email}, fn token ->
        send(parent, {:token, token})
        "http://localhost/invitations/#{token}"
      end)

    remember(client)
    {client, receive_token()}
  end

  defp invite_admin_for(owner, client, email) do
    parent = self()

    {:ok, _invitation} =
      Operators.invite_admin(owner, client.id, %{"email" => email}, fn token ->
        send(parent, {:token, token})
        "http://localhost/invitations/#{token}"
      end)

    receive_token()
  end

  defp receive_token do
    receive do
      {:token, token} -> token
    after
      0 -> flunk("no invitation's link was made")
    end
  end

  defp scope_in(user, slug, workspace_slug \\ nil) do
    {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), slug, workspace_slug)
    scope
  end

  defp clients?(%{organisation: %{id: id}}),
    do: Repo.exists?(from t in Tenant, where: t.operator_id == ^id)

  # A client is named as a race's, so a run stopped half way leaves it to the next one's
  # clean-up, and remembered, so this one's deletes it with its operator.
  defp name, do: "Races client #{System.unique_integer([:positive])}"

  defp remember(%Organisation{id: id}) do
    Agent.update(Process.get(Apiary.Races), fn created ->
      %{created | organisations: [id | created.organisations]}
    end)
  end

  # A client of the operator, its owner invited by an address of a race's: none signs up.
  defp create(owner) do
    Operators.create_client(
      owner,
      %{"name" => name(), "email" => "owner#{System.unique_integer([:positive])}@races.test"},
      &"http://localhost/invitations/#{&1}"
    )
  end
end

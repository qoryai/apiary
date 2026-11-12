defmodule ApiaryPro.AdoptionRacesTest do
  # The adoption (`ApiaryPro.Adoption.run/0`) against an account's deletion, each on a
  # connection of its own, outside the SQL sandbox, so each commits and each waits on the
  # other's locks as it would in production: an instance that ran the core until now, its
  # nodes swapped one at a time, where a person deletes their account as a node adopts.
  # Not async: the suite's instance organisation is hidden while a test runs, and what the
  # tests commit is deleted again before they end.
  #
  # The rule under test is the lock order of docs/access.md: several organisation rows
  # taken in a mode that conflicts with `FOR SHARE` are taken at one point, the clients
  # first, then the rest, each in the order of their ids. The adoption takes the
  # organisations without a tenant and the one it makes the instance organisation, which
  # here has its tenant and the lowest id, in that one pass; an account's deletion holds
  # the organisations it owns `FOR SHARE` in the same order.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Accounts, Repo}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Adoption, Tenants}
  alias ApiaryPro.Tenants.Tenant
  alias Ecto.Adapters.SQL.Sandbox

  # Older than any organisation the suite creates, the committed instance's included.
  @oldest ~U[2001-01-01 00:00:00.000000Z]

  setup_all :clean_up_leftovers
  setup_all :show_the_suites_instance_organisation
  setup :setup_races

  # The suite's instance organisation hidden, as on an instance that ran the core until
  # now; an organisation the core names its instance's own, the oldest, which has its
  # tenant and an id below the other's; an organisation the core wrote, without a tenant,
  # with the highest id there is; and a person who owns both with its first owner.
  setup do
    # Signed up while the suite's is shown, so that it is not made the instance
    # organisation as an instance's first sign-up is.
    owner = sign_up()
    instance = owner.organisation
    leaving = member(owner.scope, :owner)
    suite = Apiary.EditionKit.hide_instance_organisation()

    Repo.update_all(from(o in Organisation, where: o.id == ^instance.id),
      set: [inserted_at: @oldest]
    )

    assert Apiary.Edition.Core.instance_organisation_id() == instance.id

    tenantless = core_organisation!([owner.user.id, leaving.user.id])
    created(%{organisation: %Organisation{id: tenantless}, user: leaving.user})
    assert instance.id < tenantless

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^instance.id),
        set: [instance_organisation: false]
      )

      :ok = Apiary.EditionKit.show_instance_organisation(suite)
      Sandbox.checkin(Repo)
    end)

    %{instance: instance, tenantless: tenantless, leaving: leaving}
  end

  test "the instance organisation, with its tenant and the lowest id, is taken first", ctx do
    {later, later_pid} = hold(fn -> locked(ctx.tenantless) end)
    assert later.result == ctx.tenantless

    adoption = start(fn -> Adoption.run() end)
    await_blocked(adoption.backend, later_pid)

    # Waiting on the other, it holds the instance organisation already.
    assert held?(ctx.instance.id)
    commit(later)

    assert :ok = Task.await(adoption.task)
    assert adopted?(ctx)
  end

  test "an account's deletion that owns both, its first row held: the adoption waits, holding no other, and nothing deadlocks",
       ctx do
    before = deadlocks()

    {deletion, deletion_pid} = hold(fn -> locked(ctx.instance.id) end)
    assert deletion.result == ctx.instance.id

    adoption = start(fn -> Adoption.run() end)
    await_blocked(adoption.backend, deletion_pid)
    refute held?(ctx.tenantless)

    # The rest of the deletion, which holds the other organisation too, does not wait.
    assert {:ok, _deleted} = continue(deletion, fn -> Accounts.delete_user(ctx.leaving.user) end)
    commit(deletion)

    assert :ok = Task.await(adoption.task)
    assert adopted?(ctx)
    assert deadlocks() == before
  end

  test "the adoption first: the account's deletion waits for it", ctx do
    before = deadlocks()

    {adoption, adoption_pid} = hold(fn -> Adoption.run() end)
    assert adoption.result == :ok

    deletion = start(fn -> Accounts.delete_user(ctx.leaving.user) end)
    await_blocked(deletion.backend, adoption_pid)
    commit(adoption)

    assert {:ok, _deleted} = Task.await(deletion.task)
    assert adopted?(ctx)
    assert deadlocks() == before
  end

  # Shows the suite's instance organisation again where a stopped run left it hidden: the
  # oldest organisation in use, the first the suite created.
  defp show_the_suites_instance_organisation(_context) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    unless Repo.exists?(from t in Tenant, where: t.instance_organisation),
      do:
        Apiary.EditionKit.show_instance_organisation(
          Apiary.Edition.Core.instance_organisation_id()
        )

    Sandbox.checkin(Repo)
    :ok
  end

  # An organisation as the core wrote it, without a tenant, with the highest id there is,
  # whose owners are `owners`: its id.
  defp core_organisation!(owners) do
    tail = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> binary_part(0, 12)
    id = "ffffffff-ffff-4fff-bfff-" <> tail
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Organisation, [
        %{id: id, name: name("Core"), slug: "core-#{tail}", inserted_at: now, updated_at: now}
      ])

    for user_id <- owners,
        do: Repo.insert!(%Membership{organisation_id: id, user_id: user_id, level: :owner})

    id
  end

  # The organisation's row, held `FOR SHARE`, as an account's deletion holds one it owns.
  defp locked(id),
    do: Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR SHARE")

  # Whether another connection finds the organisation's row held so that a share of it
  # would wait.
  defp held?(id) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      query = from o in Organisation, where: o.id == ^id, select: o.id

      try do
        {:ok, ^id} = Repo.transaction(fn -> Repo.one(lock(query, "FOR SHARE NOWAIT")) end)
        false
      rescue
        e in Postgrex.Error ->
          %Postgrex.Error{postgres: %{code: :lock_not_available}} = e
          true
      end
    end)
    |> Task.await()
  end

  # The organisation without a tenant has one, and the core's own is the instance
  # organisation.
  defp adopted?(ctx) do
    Repo.exists?(from t in Tenant, where: t.organisation_id == ^ctx.tenantless) and
      Tenants.instance_organisation().id == ctx.instance.id
  end

  # Postgres's own count of deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end

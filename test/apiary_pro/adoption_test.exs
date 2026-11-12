defmodule ApiaryPro.AdoptionTest do
  @moduledoc """
  The adoption of an instance whose organisations the core created (`ApiaryPro.Adoption`):
  a tenant and its people lock for every organisation, the core's instance organisation
  made the instance organisation while there is none, of the kind `organisation` as every
  organisation adopted, a member's workspaces as they reached them in the core, and one
  entry in each adopted organisation's trail; and a second run that changes nothing.
  """
  # Not async: the adoption takes an advisory lock for its transaction, reads every
  # organisation and locks those it adopts, and a test here takes the flag off the suite's
  # instance organisation.
  use Apiary.DataCase, async: false

  alias Apiary.Access
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{Adoption, Operators, Tenants}
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}
  alias ApiaryPro.WorkspaceAccess.Row

  # Older than any organisation the suite creates, the committed instance's included.
  @oldest ~U[2001-01-01 00:00:00.000000Z]

  # An organisation as the core wrote it: no tenant, since every way the edition has
  # of creating one writes its tenant, so its rows are inserted directly. A workspace per
  # entry of `workspaces:`, `:in_use` or `:marked` for deletion, and a person at each of
  # `levels:`, each an account of their own. Its id, its workspaces' ids and its people,
  # `{user_id, level}`.
  defp core_organisation!(opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())
    now = DateTime.utc_now()
    n = System.unique_integer([:positive])
    id = Ecto.UUID.generate()

    {1, _} =
      Repo.insert_all(Organisation, [
        %{id: id, name: "Core #{n}", slug: "core-#{n}", inserted_at: inserted_at, updated_at: now}
      ])

    workspaces =
      opts
      |> Keyword.get(:workspaces, [:in_use])
      |> Enum.with_index(1)
      |> Enum.map(fn {state, i} ->
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            organisation_id: id,
            name: "Workspace #{i}",
            slug: "workspace-#{i}",
            type: "qory.software",
            inserted_at: now,
            updated_at: now
          },
          if(state == :marked,
            do: %{
              deletion_marked_at: now,
              purge_after: DateTime.add(now, 30, :day),
              purge_trigger: "grace_period"
            },
            else: %{}
          )
        )
      end)

    Repo.insert_all(Workspace, workspaces)

    people =
      for level <- Keyword.get(opts, :levels, [:owner, :admin, :member, :member]),
          do: {Ecto.UUID.generate(), level}

    account_time = DateTime.utc_now(:second)

    Repo.insert_all(
      User,
      for {user_id, _level} <- people do
        %{
          id: user_id,
          email: "core-#{System.unique_integer([:positive])}@example.com",
          confirmed_at: account_time,
          inserted_at: account_time,
          updated_at: account_time
        }
      end
    )

    Repo.insert_all(
      Membership,
      for {user_id, level} <- people do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: id,
          user_id: user_id,
          level: level,
          inserted_at: now,
          updated_at: now
        }
      end
    )

    %{id: id, workspace_ids: Enum.map(workspaces, & &1.id), people: people}
  end

  defp access(organisation_id) do
    Repo.all(
      from r in Row,
        where: r.organisation_id == ^organisation_id,
        order_by: [asc: r.workspace_id, asc: r.user_id],
        select: {r.workspace_id, r.user_id}
    )
  end

  defp adopt_entries(organisation_id) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation_id and e.action == "instance.adopt"
    )
  end

  # The scope of the account `user_id` in `organisation`, as a page of its path loads it.
  defp scope_in(user_id, organisation) do
    Apiary.Organisations.resolve_scope(
      Scope.for_user(Repo.get!(User, user_id)),
      organisation.slug,
      nil
    )
  end

  # What the adoption writes, all of it, for a comparison of before and after.
  defp written do
    {Repo.all(from t in Tenant, order_by: t.organisation_id),
     Repo.all(from p in PeopleLock, order_by: p.organisation_id),
     Repo.all(from r in Row, order_by: r.id, select: {r.id, r.workspace_id, r.user_id}),
     Repo.all(from e in Entry, where: e.action == "instance.adopt", order_by: e.id, select: e.id)}
  end

  describe "an instance without an instance organisation" do
    setup do
      # The edition's instance organisation hidden, as on an instance that ran the
      # core until now. The core names the oldest organisation in use its instance's
      # (`Apiary.Edition.Core.instance_organisation_id/0`), which on a core instance is
      # the one its first sign-up created: the test's is given the oldest `inserted_at`,
      # rather than the suite's being marked for deletion, so that the suite's committed
      # organisation is changed only as the kit hides it.
      Apiary.EditionKit.hide_instance_organisation()
      instance = core_organisation!(inserted_at: @oldest, workspaces: [:in_use, :in_use])
      assert Apiary.Edition.Core.instance_organisation_id() == instance.id
      %{instance: instance}
    end

    test "is adopted: a tenant each, the core's own organisation the instance organisation",
         %{instance: instance} do
      other = core_organisation!(workspaces: [:in_use, :marked])
      owners_only = core_organisation!(workspaces: [:in_use, :in_use], levels: [:owner])

      assert :ok = Adoption.run()

      # An organisation, as every organisation adopted: adopting makes no operator.
      assert %Tenant{
               kind: :organisation,
               instance_organisation: true,
               operator_id: nil,
               operator_since: nil,
               suspended_at: nil
             } = Repo.get!(Tenant, instance.id)

      assert Tenants.instance_organisation_id() == instance.id

      for %{id: id} <- [other, owners_only] do
        assert %Tenant{
                 kind: :organisation,
                 instance_organisation: false,
                 operator_id: nil,
                 operator_since: nil,
                 suspended_at: nil,
                 suspended_by_id: nil
               } = Repo.get!(Tenant, id)
      end

      # Each with its people lock beside its tenant, as every tenant has.
      for %{id: id} <- [instance, other, owners_only] do
        assert %PeopleLock{inserted_at: %DateTime{}} = Repo.get!(PeopleLock, id)
      end

      # A member reaches every workspace they reached in the core, one marked for
      # deletion among them; an owner or an admin reaches every workspace without a row.
      for organisation <- [instance, other, owners_only] do
        reached =
          for {user_id, :member} <- organisation.people,
              workspace_id <- organisation.workspace_ids,
              do: {workspace_id, user_id}

        assert access(organisation.id) == Enum.sort(reached)
      end

      assert length(access(instance.id)) == 4
      assert access(owners_only.id) == []

      for {organisation, kind, instance_organisation?} <- [
            {instance, "organisation", true},
            {other, "organisation", false},
            {owners_only, "organisation", false}
          ] do
        assert [entry] = adopt_entries(organisation.id)
        assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
        assert {entry.subject_kind, entry.subject_id} == {"organisation", organisation.id}
        assert entry.after == %{"kind" => kind}
        assert entry.details["instance_organisation"] == instance_organisation?
        assert entry.details["workspace_access"] == length(access(organisation.id))
      end
    end

    @tag with_features: Apiary.Features.all()
    test "its owners are the instance admins of a plain organisation, which they may make an operator",
         %{instance: instance} do
      assert :ok = Adoption.run()

      {owner_id, :owner} = List.keyfind(instance.people, :owner, 1)
      organisation = Repo.get!(Organisation, instance.id)
      assert {:ok, scope} = scope_in(owner_id, organisation)

      assert Access.instance_admin?(scope)
      assert Access.can?(scope, :"instance.read", scope.organisation)
      refute Tenants.operator?(scope.organisation)

      # No Clients page: an operator's actions are not found in an organisation.
      assert Access.check(scope, :"client.read", scope.organisation) == {:error, :not_found}

      # With `managed_organisations`, which the suite's instance has, an instance admin
      # makes it an operator on Instance settings › Organisations, and it has a Clients page then.
      assert {:ok, operator} = Operators.change_kind(scope, instance.id, :operator)

      assert %Tenant{kind: :operator, instance_organisation: true} =
               Repo.get!(Tenant, operator.id)

      assert {:ok, scope} = scope_in(owner_id, organisation)
      assert Access.can?(scope, :"client.read", scope.organisation)
    end

    test "leaves the kind as it is of one that had its tenant already" do
      # The core's instance organisation, older than the setup's, with a tenant of its own
      # of the kind operator, as an earlier run could have left it: the flag is set, and
      # the kind stays.
      core = core_organisation!(inserted_at: DateTime.add(@oldest, -1, :day))
      now = DateTime.utc_now()

      Repo.insert!(%Tenant{
        organisation_id: core.id,
        kind: :operator,
        inserted_at: now,
        updated_at: now
      })

      assert :ok = Adoption.run()

      assert %Tenant{kind: :operator, instance_organisation: true} = Repo.get!(Tenant, core.id)
      assert [entry] = adopt_entries(core.id)
      assert entry.after == %{"kind" => "operator"}
      assert entry.details["instance_organisation"] == true
    end

    test "is adopted once: a second run changes nothing, and gives no access back",
         %{instance: instance} do
      other = core_organisation!(workspaces: [:in_use, :in_use])
      assert :ok = Adoption.run()

      assert [_, _, _, _] = access(other.id)
      taken = Repo.one!(from r in Row, where: r.organisation_id == ^other.id, limit: 1)
      Repo.delete!(taken)
      before = written()

      assert :ok = Adoption.run()

      assert written() == before
      refute {taken.workspace_id, taken.user_id} in access(other.id)
      assert [_] = adopt_entries(instance.id)
      assert [_] = adopt_entries(other.id)
    end
  end

  describe "an instance with an instance organisation" do
    test "keeps it: no organisation adopted becomes the instance organisation" do
      id = Tenants.instance_organisation_id()
      suites = Repo.get!(Tenant, id)

      # The one the core would name its instance's, were it asked.
      oldest = core_organisation!(inserted_at: @oldest)
      other = core_organisation!()
      assert Apiary.Edition.Core.instance_organisation_id() == oldest.id

      assert :ok = Adoption.run()

      assert Tenants.instance_organisation_id() == id
      assert Repo.get!(Tenant, id) == suites

      for organisation <- [oldest, other] do
        assert %Tenant{kind: :organisation, instance_organisation: false} =
                 Repo.get!(Tenant, organisation.id)

        assert [entry] = adopt_entries(organisation.id)
        assert entry.after == %{"kind" => "organisation"}
        assert entry.details["instance_organisation"] == false
      end
    end

    # The window between the adoption's read and its lock, injected: what `run/0` read is
    # handed to the step after it (`ApiaryPro.Adoption.adopt/2`) once another node has
    # given one of those organisations its tenant, as a change of its kind would on a node
    # that runs the edition already.
    test "adopts only what is still without a tenant once the rows are locked" do
      gained = core_organisation!()
      still = core_organisation!()
      read = Repo.all(from o in Organisation, where: o.id in ^[gained.id, still.id])

      now = DateTime.utc_now()

      Repo.insert!(%Tenant{
        organisation_id: gained.id,
        kind: :operator,
        inserted_at: now,
        updated_at: now
      })

      Repo.insert!(%PeopleLock{organisation_id: gained.id, inserted_at: now})

      assert {:ok, [adopted]} = Repo.transact(fn -> {:ok, Adoption.adopt(read, nil)} end)
      assert adopted == still.id

      # The other node's tenant stays as it wrote it, and nothing of an adoption is added.
      assert %Tenant{kind: :operator} = Repo.get!(Tenant, gained.id)
      assert access(gained.id) == []
      assert adopt_entries(gained.id) == []

      assert %Tenant{kind: :organisation} = Repo.get!(Tenant, still.id)
      assert access(still.id) != []
      assert [_entry] = adopt_entries(still.id)
    end
  end
end

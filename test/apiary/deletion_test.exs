defmodule Apiary.DeletionTest do
  # Not async: the purge is asked on an instance with every feature, so each table holds
  # rows, and the grace period's setting is the node's.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{AccessKeys, Deletion, Features, Organisations, Policy, Retention}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry

  alias Apiary.Deletion.{
    PurgedOrganisation,
    PurgeOrganisationJob,
    PurgeSweep,
    PurgeWorkspaceJob,
    Tables
  }

  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Batch, Ingest, Projector}

  @moduletag with_features: Features.all()

  setup do
    owner = sign_up_fixture()
    %{owner: owner, scope: owner.scope}
  end

  describe "deleting a workspace" do
    test "marks it: gone from every page, its keys refused, nothing removed", %{scope: scope} do
      workspace = workspace_fixture(scope.organisation, "Staging")
      there = workspace_scope(scope.user, workspace)
      member = member_fixture(there, :member)
      %{access_key: key} = access_key_fixture(there)
      %{token: token} = invitation_fixture(there)
      run = run_fixture(there)

      assert {:ok, marked} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
      assert %DateTime{} = marked.deletion_marked_at
      assert marked.deletion_marked_by_id == scope.user.id
      assert marked.purge_trigger == "grace_period"
      assert DateTime.diff(marked.purge_after, marked.deletion_marked_at, :day) == 30

      refute workspace.id in Enum.map(Organisations.list_workspaces(scope), & &1.id)
      assert [%Workspace{id: id}] = Deletion.list_marked_workspaces(scope)
      assert id == workspace.id

      # Its member stays in the organisation, and reaches the workspace no more.
      assert [membership] = Organisations.list_memberships(member.user)
      assert membership.organisation_id == scope.organisation.id
      refute workspace.id in Enum.map(membership.workspaces, & &1.id)
      assert workspace_scope(member.user, workspace) == nil
      assert workspace_scope(scope.user, workspace) == nil

      assert AccessKeys.fetch_for_verification(key.key_id) == :error
      assert Organisations.get_invitation_by_token(token) == nil

      # Nothing is removed yet.
      assert Repo.get(Apiary.Runs.Run, run.id)
      assert Repo.get(Apiary.AccessKeys.AccessKey, key.id)
      assert Repo.get(Apiary.Organisations.Membership, member.membership.id)
    end

    test "asks for the slug, an owner or an admin, and another workspace", %{scope: scope} do
      assert {:error, :last_workspace} =
               Deletion.delete_workspace(scope, scope.workspace.id, scope.workspace.slug)

      workspace = workspace_fixture(scope.organisation)
      %{scope: member} = member_fixture(scope, :member)

      assert {:error, :confirmation} = Deletion.delete_workspace(scope, workspace.id, "nope")
      assert {:error, :confirmation} = Deletion.delete_workspace(scope, workspace.id, nil)

      assert {:error, :forbidden} =
               Deletion.delete_workspace(member, workspace.id, workspace.slug)

      %{scope: other} = sign_up_fixture()
      assert {:error, :not_found} = Deletion.delete_workspace(other, workspace.id, workspace.slug)
      assert {:error, :not_found} = Deletion.delete_workspace(scope, "not-an-id", "x")

      %{scope: admin} = member_fixture(scope, :admin)
      assert {:ok, _} = Deletion.delete_workspace(admin, workspace.id, " #{workspace.slug} ")
      assert {:error, :not_found} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    end

    test "restoring brings it back as it was, keys and access included", %{scope: scope} do
      workspace = workspace_fixture(scope.organisation)
      member = member_fixture(workspace_scope(scope.user, workspace), :member)
      %{access_key: key} = access_key_fixture(workspace_scope(scope.user, workspace))
      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

      assert {:error, :forbidden} = Deletion.restore_workspace(member.scope, workspace.id)

      %{scope: admin} = member_fixture(scope, :admin)
      assert {:ok, restored} = Deletion.restore_workspace(admin, workspace.id)
      assert is_nil(restored.deletion_marked_at) and is_nil(restored.purge_after)
      assert is_nil(restored.purge_trigger)
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)
      assert workspace_scope(member.user, workspace)

      assert {:error, :not_found} = Deletion.restore_workspace(scope, workspace.id)
    end

    test "once the grace period is over it can no longer be cancelled", %{scope: scope} do
      workspace = workspace_fixture(scope.organisation)
      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
      overdue!(Workspace, workspace.id)

      assert {:error, :purge_started} = Deletion.restore_workspace(scope, workspace.id)
    end

    test "a purge that claimed it first wins over a cancelling, and one after loses",
         %{scope: scope} do
      claimed = workspace_fixture(scope.organisation)
      restored = workspace_fixture(scope.organisation)

      for workspace <- [claimed, restored] do
        {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
      end

      # A purge that claimed the workspace, and has not finished yet: no cancelling.
      claim!(Workspace, claimed.id)
      assert {:error, :purge_started} = Deletion.restore_workspace(scope, claimed.id)
      assert Repo.get!(Workspace, claimed.id).deletion_marked_at

      # A cancelling first: the purge that comes after finds nothing to do.
      assert {:ok, _} = Deletion.restore_workspace(scope, restored.id)
      instance = Scope.for_instance(scope.organisation, Repo.get!(Workspace, restored.id))
      assert {:ok, :not_due} = Deletion.purge_workspace(instance)
      assert Repo.get(Workspace, restored.id)
    end
  end

  describe "deleting an organisation" do
    test "marks it: gone for every member, its keys refused, its owners see it", ctx do
      %{scope: scope} = ctx
      member = member_fixture(scope)
      %{scope: admin} = member_fixture(scope, :admin)
      %{access_key: key} = access_key_fixture(scope)
      %{token: token} = invitation_fixture(scope)

      assert {:error, :confirmation} = Deletion.delete_organisation(scope, "acme")
      assert {:error, :forbidden} = Deletion.delete_organisation(member.scope, "x")

      assert {:error, :forbidden} =
               Deletion.delete_organisation(admin, scope.organisation.slug)

      assert {:ok, marked} = Deletion.delete_organisation(scope, scope.organisation.slug)
      assert marked.deletion_marked_by_id == scope.user.id

      for person <- [ctx.owner.user, member.user] do
        assert Organisations.list_memberships(person) == []
        assert Organisations.load_scope(Scope.for_user(person)).organisation == nil

        assert :error =
                 Organisations.resolve_scope(Scope.for_user(person), scope.organisation.slug)
      end

      assert AccessKeys.fetch_for_verification(key.key_id) == :error
      assert Organisations.get_invitation_by_token(token) == nil

      assert [%Organisation{id: id}] = Deletion.list_marked_organisations(scope)
      assert id == scope.organisation.id
      assert Deletion.list_marked_organisations(member.scope) == []
      assert Deletion.list_marked_organisations(admin) == []
      assert {:error, :not_found} = Deletion.delete_organisation(scope, scope.organisation.slug)
    end

    test "an owner cancels it during the grace period, and everything is back", ctx do
      %{scope: scope} = ctx
      member = member_fixture(scope)
      %{scope: admin} = member_fixture(scope, :admin)
      %{access_key: key} = access_key_fixture(scope)
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      assert {:error, :forbidden} =
               Deletion.restore_organisation(member.scope, scope.organisation.id)

      assert {:error, :forbidden} = Deletion.restore_organisation(admin, scope.organisation.id)

      %{scope: stranger} = sign_up_fixture()

      assert {:error, :not_found} =
               Deletion.restore_organisation(stranger, scope.organisation.id)

      assert {:ok, restored} =
               Deletion.restore_organisation(
                 Scope.for_user(ctx.owner.user),
                 scope.organisation.id
               )

      assert is_nil(restored.deletion_marked_at)
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)
      assert [_] = Organisations.list_memberships(member.user)
      assert Deletion.list_marked_organisations(scope) == []
    end

    test "once the grace period is over, or a purge claimed it, it stays deleted",
         %{scope: scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      overdue!(Organisation, scope.organisation.id)

      assert {:error, :purge_started} =
               Deletion.restore_organisation(scope, scope.organisation.id)

      %{scope: claimed} = sign_up_fixture()
      {:ok, _} = Deletion.delete_organisation(claimed, claimed.organisation.slug)
      claim!(Organisation, claimed.organisation.id)

      assert {:error, :purge_started} =
               Deletion.restore_organisation(claimed, claimed.organisation.id)
    end

    test "a cancelling before the purge runs leaves the purge nothing to do", %{scope: scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      {:ok, _} = Deletion.restore_organisation(scope, scope.organisation.id)

      assert {:ok, :not_due} =
               Deletion.purge_organisation(Scope.for_instance(scope.organisation))

      assert Repo.get!(Organisation, scope.organisation.id).purge_started_at == nil
    end
  end

  describe "a page opened before the marking" do
    test "acts on nothing after it", %{scope: scope} do
      workspace = workspace_fixture(scope.organisation)
      there = workspace_scope(scope.user, workspace)
      %{user: user} = member_fixture(there, :member)
      member = workspace_scope(user, workspace)
      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

      # The scopes still say the workspace is in use; asked, the database says otherwise.
      assert Apiary.Access.can?(member, :"node.read", member.workspace)
      assert Apiary.Access.can?(there, :"node.create", there.workspace)
      late = %{"kind" => "node", "name" => "late"}
      assert {:error, :not_found} = Apiary.Nodes.create_node(there, late)

      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      assert {:error, :not_found} = Organisations.update_organisation(scope, %{name: "Late"})
      assert {:error, :not_found} = Apiary.Audit.list_entries(scope)
    end

    test "a job of a marked organisation is cancelled, not retried", %{scope: scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      assert {:cancel, :marked} =
               perform_job(Apiary.Audit.PruneJob, %{
                 "organisation_id" => scope.organisation.id,
                 "workspace_id" => nil
               })
    end
  end

  describe "the purge" do
    test "a workspace's: every row of it, in every table, and nothing of another", ctx do
      %{scope: scope} = ctx
      workspace = workspace_fixture(scope.organisation)
      inside = workspace_scope(scope.user, workspace)
      member = member_fixture(inside, :member)
      fill!(inside)
      fill!(scope)
      # The workspace its member last used, which goes with it.
      :ok = Apiary.Organisations.remember_workspace(workspace_scope(member.user, workspace))
      %{scope: other} = sign_up_fixture()
      fill!(other)

      held = counts(workspace_id: workspace.id)
      assert Enum.count(held, fn {_table, n} -> n > 0 end) >= 10, inspect(held)
      kept_here = counts(workspace_id: scope.workspace.id)
      kept_there = counts(organisation_id: other.organisation.id)

      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
      instance = Scope.for_instance(scope.organisation, workspace)

      # Not yet due: nothing happens.
      assert {:ok, :not_due} = Deletion.purge_workspace(instance)
      assert counts(workspace_id: workspace.id) == held

      overdue!(Workspace, workspace.id)
      assert {:ok, :purged} = Deletion.purge_workspace(instance)

      assert Enum.all?(counts(workspace_id: workspace.id), fn {_table, n} -> n == 0 end)
      assert Repo.get(Workspace, workspace.id) == nil
      assert counts(workspace_id: scope.workspace.id) == kept_here

      # Its member stays in the organisation: only the workspace went.
      assert Repo.get(Apiary.Organisations.Membership, member.membership.id)
      assert counts(organisation_id: other.organisation.id) == kept_there

      assert %Entry{action: "workspace.purge", workspace_id: nil, actor_kind: :instance} =
               Repo.one(
                 from e in Entry,
                   where: e.subject_id == ^workspace.id and e.action == "workspace.purge"
               )

      # A retry finds it gone, and completes.
      assert :ok =
               perform_job(PurgeWorkspaceJob, %{
                 "organisation_id" => scope.organisation.id,
                 "workspace_id" => workspace.id
               })
    end

    test "an organisation's: every row, its trail, and one line at the instance", ctx do
      %{scope: scope} = ctx
      fill!(scope)
      %{scope: other} = sign_up_fixture()
      fill!(other)
      id = scope.organisation.id

      held = counts(organisation_id: id)
      assert Enum.count(held, fn {_table, n} -> n > 0 end) >= 11, inspect(held)
      kept = counts(organisation_id: other.organisation.id)

      {:ok, marked} = Deletion.delete_organisation(scope, scope.organisation.slug)
      overdue!(Organisation, id)

      assert :ok =
               perform_job(PurgeOrganisationJob, %{"organisation_id" => id, "workspace_id" => nil})

      assert Enum.all?(counts(organisation_id: id), fn {_table, n} -> n == 0 end)
      assert Repo.get(Organisation, id) == nil
      assert counts(organisation_id: other.organisation.id) == kept

      assert %PurgedOrganisation{
               marked_by_id: marked_by,
               trigger: "grace_period",
               purged_at: %DateTime{}
             } = line = Repo.get!(PurgedOrganisation, id)

      assert marked_by == scope.user.id
      assert DateTime.compare(line.marked_at, marked.deletion_marked_at) == :eq

      # A retry, and a sweep, find it gone: nothing more, and still one line.
      assert :ok =
               perform_job(PurgeOrganisationJob, %{"organisation_id" => id, "workspace_id" => nil})

      assert {:ok, :gone} = Deletion.purge_organisation(Scope.for_instance(marked))
      assert Repo.aggregate(PurgedOrganisation, :count) == 1

      # The person's account is no organisation's, and stays.
      assert Repo.get(Apiary.Accounts.User, scope.user.id)
    end

    test "a purge that stopped half way goes on where it stopped", %{scope: scope} do
      fill!(scope)
      id = scope.organisation.id
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      overdue!(Organisation, id)

      # As if an attempt had deleted the record and stopped before the rest.
      Repo.delete_all(from r in Apiary.Runs.Run, where: r.organisation_id == ^id)

      assert {:ok, :purged} =
               Deletion.purge_organisation(Scope.for_instance(%Organisation{id: id}))

      assert Enum.all?(counts(organisation_id: id), fn {_table, n} -> n == 0 end)
      assert Repo.get(PurgedOrganisation, id)
    end

    test "one restored before its purge ran is left alone", %{scope: scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      {:ok, _} = Deletion.restore_organisation(scope, scope.organisation.id)

      assert :ok =
               perform_job(PurgeOrganisationJob, %{
                 "organisation_id" => scope.organisation.id,
                 "workspace_id" => nil
               })

      assert Repo.get(Organisation, scope.organisation.id)
      refute Repo.get(PurgedOrganisation, scope.organisation.id)
    end

    test "only the instance purges", %{scope: scope} do
      {:ok, organisation} = Deletion.delete_organisation(scope, scope.organisation.slug)
      overdue!(Organisation, organisation.id)

      assert {:error, :forbidden} = Deletion.purge_organisation(scope)
      assert Repo.get(Organisation, organisation.id)
    end

    test "the sweep enqueues one purge for each deletion that is due, and nothing else",
         %{scope: scope} do
      due = workspace_fixture(scope.organisation)
      waiting = workspace_fixture(scope.organisation)
      {:ok, _} = Deletion.delete_workspace(scope, due.id, due.slug)
      {:ok, _} = Deletion.delete_workspace(scope, waiting.id, waiting.slug)
      overdue!(Workspace, due.id)

      %{scope: gone} = sign_up_fixture()
      {:ok, _} = Deletion.delete_organisation(gone, gone.organisation.slug)
      overdue!(Organisation, gone.organisation.id)

      # A workspace of an organisation that is purged goes with it.
      %{scope: going} = sign_up_fixture()
      inner = workspace_fixture(going.organisation)
      {:ok, _} = Deletion.delete_workspace(going, inner.id, inner.slug)
      overdue!(Workspace, inner.id)
      {:ok, _} = Deletion.delete_organisation(going, going.organisation.slug)

      assert :ok = perform_job(PurgeSweep, %{})

      assert [%{args: %{"workspace_id" => workspace_id}}] =
               all_enqueued(worker: PurgeWorkspaceJob)

      assert workspace_id == due.id

      assert [%{args: %{"organisation_id" => organisation_id}}] =
               all_enqueued(worker: PurgeOrganisationJob)

      assert organisation_id == gone.organisation.id

      # Run again while those wait: nothing more.
      assert :ok = perform_job(PurgeSweep, %{})
      assert length(all_enqueued(worker: PurgeWorkspaceJob)) == 1
      assert length(all_enqueued(worker: PurgeOrganisationJob)) == 1
    end

    test "the sweep is in the crontab, once a day" do
      crontab = Application.get_env(:apiary, Oban)[:crontab]
      assert {expression, PurgeSweep} = List.keyfind(crontab, PurgeSweep, 1)
      assert {:ok, _} = Oban.Cron.Expression.parse(expression)
    end

    test "purge_now purges at once, marked or not, and records who asked", %{scope: scope} do
      fill!(scope)
      id = scope.organisation.id
      %{user: admin} = sign_up_fixture()

      assert {:ok, :purged} = Deletion.purge_now(scope.organisation, admin)
      assert Repo.get(Organisation, id) == nil
      assert Enum.all?(counts(organisation_id: id), fn {_table, n} -> n == 0 end)

      assert %PurgedOrganisation{
               trigger: "erasure_request",
               marked_by_id: nil,
               requested_by_id: requested_by
             } = Repo.get!(PurgedOrganisation, id)

      assert requested_by == admin.id

      # One an owner deleted already is an erasure request all the same, and keeps who
      # marked it.
      %{scope: deleted} = sign_up_fixture()
      {:ok, _} = Deletion.delete_organisation(deleted, deleted.organisation.slug)
      assert {:ok, :purged} = Deletion.purge_now(deleted.organisation, admin)

      assert %PurgedOrganisation{
               trigger: "erasure_request",
               marked_by_id: marked_by,
               requested_by_id: requested_by
             } = Repo.get!(PurgedOrganisation, deleted.organisation.id)

      assert marked_by == deleted.user.id
      assert requested_by == admin.id
    end

    test "an erasure request the sweep finishes still says it was one", %{scope: scope} do
      %{user: admin} = sign_up_fixture()

      # As `purge_now/3` leaves the row when its purge stops before it is done.
      Repo.update_all(from(o in Organisation, where: o.id == ^scope.organisation.id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_requested_by_id: admin.id,
          purge_after: DateTime.add(DateTime.utc_now(), -1, :second),
          purge_trigger: "erasure_request"
        ]
      )

      assert :ok =
               perform_job(PurgeOrganisationJob, %{
                 "organisation_id" => scope.organisation.id,
                 "workspace_id" => nil
               })

      assert %PurgedOrganisation{trigger: "erasure_request", requested_by_id: requested_by} =
               Repo.get!(PurgedOrganisation, scope.organisation.id)

      assert requested_by == admin.id
    end

    test "a render again leaves out a workspace gone or claimed, and renders a marked one",
         %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      assert {:ok, _} = Policy.rerender(Ecto.UUID.generate())

      marked = workspace_fixture(scope.organisation)
      {:ok, _} = Policy.allow(workspace_scope(scope.user, marked), nil, %{host: "api.example"})
      {:ok, _} = Deletion.delete_workspace(scope, marked.id, marked.slug)
      assert {:ok, _} = Policy.rerender(marked.id)

      claim!(Workspace, marked.id)
      assert {:ok, 0} = Policy.rerender(marked.id)
      assert %{workspaces: _, versions: _} = Policy.rerender_all()
    end

    test "retention leaves a marked workspace alone", %{scope: scope} do
      {:ok, _} = Retention.update_retention(scope, %{events_retention_days: 1})
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      assert {:ok, results} = Retention.prune_all()
      refute scope.workspace.id in Enum.map(results, & &1.workspace_id)
    end
  end

  describe "DELETION_GRACE_DAYS" do
    test "30 when unset, a number of days from 1 to 90" do
      assert Deletion.parse_grace_days(nil) == {:ok, 30}
      assert Deletion.parse_grace_days(" ") == {:ok, 30}
      assert Deletion.parse_grace_days("1") == {:ok, 1}
      assert Deletion.parse_grace_days(" 90 ") == {:ok, 90}

      for value <- ["0", "91", "-1", "a month", "7.5"] do
        assert {:error, reason} = Deletion.parse_grace_days(value)
        assert reason =~ "1 to 90"
      end
    end

    test "a value refused stops the boot; one accepted is the grace period", %{scope: scope} do
      previous =
        Map.new(~w(deletion_grace_setting deletion_grace_days)a, fn key ->
          {key, Application.get_env(:apiary, key)}
        end)

      on_exit(fn ->
        for {key, value} <- previous, do: Application.put_env(:apiary, key, value)
      end)

      Application.put_env(:apiary, :deletion_grace_setting, "0")
      assert_raise ArgumentError, ~r/DELETION_GRACE_DAYS/, fn -> Deletion.boot!() end

      Application.put_env(:apiary, :deletion_grace_setting, "7")
      assert Deletion.boot!() == 7

      {:ok, marked} = Deletion.delete_organisation(scope, scope.organisation.slug)
      assert DateTime.diff(marked.purge_after, marked.deletion_marked_at, :day) == 7
    end
  end

  describe "the edition's part" do
    test "the core's edition refuses the instance's organisation, and nothing else",
         %{scope: scope} do
      core = Apiary.Edition.Core
      instance = Repo.get!(Organisation, core.instance_organisation_id())

      assert core.deletion_refusal(:delete, instance) == :instance_organisation
      assert core.deletion_refusal(:purge, instance) == :instance_organisation
      assert core.deletion_refusal(:delete, scope.organisation) == nil
      assert core.deletion_refusal(:delete, scope.workspace) == nil
    end

    test "a refusal touches nothing: the instance's organisation is not purged" do
      instance = Repo.get!(Organisation, Apiary.Edition.instance_organisation_id())
      refusal = Apiary.Edition.deletion_refusal(:purge, instance)

      assert refusal
      assert {:error, ^refusal} = Deletion.purge_now(instance)
      assert %Organisation{deletion_marked_at: nil} = Repo.get!(Organisation, instance.id)
    end
  end

  ## Helpers

  # What a workspace holds, made the way the product makes it where it can: a key, an
  # invitation, a policy rule with its run configuration, a run delivered through the
  # receiver with its events, log and connections, and a retention run.
  defp fill!(%Scope{} = scope) do
    %{access_key: key} = access_key_fixture(scope)
    invitation_fixture(scope)
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

    {subject, events} = first_events()
    {:ok, batch} = events |> Jason.encode!() |> Batch.parse()

    {:ok, _} =
      Ingest.ingest(%{key | workspace: scope.workspace}, batch, %{
        contract_version: 1,
        delivery_id: Ecto.UUID.generate()
      })

    run = Repo.one!(from r in Apiary.Runs.Run, where: r.run_id == ^subject)
    events_fixture(run, Enum.drop(record(), 2))
    {:ok, _} = Projector.project(run)

    {:ok, workspace} = Retention.update_retention(scope, %{events_retention_days: 3650})
    Retention.prune_workspace(workspace)
    :ok = Apiary.Organisations.remember_workspace(scope)
  end

  defp counts(filter) do
    {column, id} = hd(filter)
    tables = if column == :workspace_id, do: Tables.workspace_tables(), else: Tables.tables()

    Map.new(tables, fn table ->
      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [Ecto.UUID.dump!(id)])

      {table, n}
    end)
  end

  defp overdue!(schema, id) do
    Repo.update_all(from(r in schema, where: r.id == ^id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )
  end

  # As a purge leaves the row once it has claimed it and before it is done.
  defp claim!(schema, id) do
    Repo.update_all(from(r in schema, where: r.id == ^id),
      set: [
        purge_after: DateTime.add(DateTime.utc_now(), -60, :second),
        purge_started_at: DateTime.utc_now()
      ]
    )
  end
end

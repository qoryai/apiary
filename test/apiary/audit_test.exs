defmodule Apiary.AuditTest do
  # Not async: the changes are made on an instance with every feature, which is the node's
  # (`Apiary.AuditCase`).
  use Apiary.AuditCase, changes: [Apiary.AuditChanges], covers: :core

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Audit, Deletion, Organisations, Retention}

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry

  # Every action of the core is audited unless `Apiary.Audit.not_audited/0` says why not
  # (`Apiary.Audit.audited?/1`, which the Activity page's filter asks too). The case makes
  # the change of every audited action, by `Apiary.AuditChanges`, and finds exactly one
  # entry of it, and none when it is refused: an audited action none of its modules makes
  # fails there.

  test "the application has no way to change or delete an entry but the prune" do
    functions = Keyword.keys(Audit.__info__(:functions))

    for name <- functions, text = Atom.to_string(name) do
      refute text =~ ~r/update|delete|change_|edit|put/, "Apiary.Audit.#{name}"
    end

    assert :prune in functions
  end

  describe "what the application removes of its own accord" do
    setup do: owner()

    test "an invitation that could not be delivered is withdrawn, and the trail says so",
         ctx do
      previous = Application.fetch_env!(:apiary, Apiary.Mailer)
      Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
      before = entries()

      assert {:error, :delivery_failed} =
               Organisations.invite_member(
                 ctx.scope,
                 %{"email" => unique_user_email()},
                 &"http://localhost/invitations/#{&1}"
               )

      assert [invited, withdrawn] = entries() -- before
      assert %Entry{action: "member.invite", subject_kind: "invitation"} = invited

      assert %Entry{
               action: "invitation.revoke",
               before: nil,
               details: %{"reason" => "undelivered"}
             } = withdrawn

      assert withdrawn.subject_id == invited.subject_id
      assert {withdrawn.actor_kind, withdrawn.actor_id} == {:person, ctx.scope.user.id}
      assert Repo.all(Apiary.Organisations.Invitation) == []
    end

    test "an invitation revoked while its email was being sent is not withdrawn again",
         ctx do
      relay_that_times_out()
      Process.put(:during_delivery, fn _email -> {:ok, _} = revoke_pending(ctx.scope) end)
      before = entries()

      assert {:error, :delivery_failed} = invite(ctx.scope)

      assert [%Entry{action: "member.invite"}, %Entry{action: "invitation.revoke"} = revoked] =
               entries() -- before

      # The owner's revocation, and no withdrawal beside it.
      assert revoked.details == nil
      assert Repo.all(Apiary.Organisations.Invitation) == []
    end

    test "an invitation accepted while its email was being sent stands: it arrived", ctx do
      # Signed up first: the fixture confirms its person by email, on the real relay.
      %{user: invitee} = sign_up_fixture()
      relay_that_times_out()

      Process.put(:during_delivery, fn _email ->
        {:ok, _} = Organisations.accept_invitation(invitee, Process.get(:invitation_token))
      end)

      before = entries()

      assert {:ok, %Apiary.Organisations.Invitation{accepted_at: %DateTime{}} = invitation} =
               invite(ctx.scope)

      assert [%Entry{action: "member.invite"}, %Entry{action: "invitation.accept"}] =
               entries() -- before

      # Accepted, it is deleted: its acceptance's entry is what says it arrived.
      assert Repo.get(Apiary.Organisations.Invitation, invitation.id) == nil
      assert [_] = Apiary.Organisations.list_memberships(invitee) |> Enum.drop(1)
    end

    test "an expired invitation replaced by a new one is an entry of its own", ctx do
      email = unique_user_email()
      %{invitation: expired} = invitation_fixture(ctx.scope, %{"email" => email})

      Repo.update_all(from(i in Apiary.Organisations.Invitation, where: i.id == ^expired.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      before = entries()
      %{invitation: invitation} = invitation_fixture(ctx.scope, %{"email" => email})

      assert [removed, invited] = entries() -- before

      assert %Entry{action: "invitation.revoke", details: %{"reason" => "expired"}} = removed
      assert removed.subject_id == expired.id
      assert removed.actor_id == ctx.scope.user.id
      assert %Entry{action: "member.invite"} = invited
      assert invited.subject_id == invitation.id
      refute_personal(removed, nil)
    end

    test "an invitation expired for 30 days is deleted by the sweep, by the instance", ctx do
      %{invitation: old} = invitation_fixture(ctx.scope)
      %{invitation: recent} = invitation_fixture(ctx.scope)
      expire!(old, 31)
      expire!(recent, 29)
      before = entries()

      assert :ok =
               perform_job(Apiary.Organisations.OldInvitationsJob, %{
                 "organisation_id" => ctx.scope.organisation.id,
                 "workspace_id" => nil
               })

      assert [removed] = entries() -- before

      assert %Entry{
               action: "invitation.revoke",
               actor_kind: :instance,
               before: nil,
               details: %{"reason" => "expired"},
               worker: "Apiary.Organisations.OldInvitationsJob"
             } = removed

      assert removed.subject_id == old.id
      refute_personal(removed, nil)
      assert Repo.get(Apiary.Organisations.Invitation, old.id) == nil
      assert Repo.get(Apiary.Organisations.Invitation, recent.id)
    end

    test "a deleted account ends each membership, an entry in each organisation", ctx do
      %{user: user, membership: here} = member_fixture(ctx.scope, :owner)
      %{organisation: own} = signed_up = sign_up_fixture()
      %{membership: there} = member_fixture(signed_up.scope, :owner)
      person = Repo.get!(User, there.user_id)
      before = entries()

      assert {:ok, _} = Accounts.delete_user(%Scope{user: user})
      assert [%Entry{action: "member.remove"} = entry] = entries() -- before
      assert entry.subject_id == here.id
      assert entry.organisation_id == ctx.scope.organisation.id
      assert {entry.actor_kind, entry.actor_id} == {:person, user.id}

      assert entry.details == %{"user_id" => user.id, "reason" => "account_deleted"}
      assert entry.before == %{"level" => "owner"}
      refute_personal(entry, nil)

      # By the instance, for a release command: the entry is the instance's.
      before = entries()
      assert {:ok, _} = Accounts.delete_user(person, origin: %{worker: "release"})

      assert [%Entry{action: "member.remove", actor_kind: :instance} = entry] =
               entries() -- before

      assert entry.organisation_id == own.id
    end
  end

  describe "which trail, and what is no change" do
    setup do: owner()

    test "a workspace's deletion, cancelling and purge are the organisation's entries", ctx do
      workspace = workspace_fixture(ctx.scope.organisation)
      {:ok, _} = Deletion.delete_workspace(ctx.scope, workspace.id, workspace.slug)
      {:ok, _} = Deletion.restore_workspace(ctx.scope, workspace.id)
      {:ok, _} = Deletion.delete_workspace(ctx.scope, workspace.id, workspace.slug)

      Repo.update_all(from(w in Apiary.Organisations.Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      {:ok, :purged} =
        Deletion.purge_workspace(Scope.for_instance(ctx.scope.organisation, workspace))

      kept =
        Repo.all(
          from e in Entry,
            where: e.subject_id == ^workspace.id,
            order_by: [asc: e.inserted_at, asc: e.id]
        )

      assert ~w(workspace.delete workspace.restore workspace.delete workspace.purge) ==
               Enum.map(kept, & &1.action)

      assert Enum.all?(kept, &is_nil(&1.workspace_id))
      assert Enum.all?(kept, &(&1.organisation_id == ctx.scope.organisation.id))
    end

    test "an edit that changes nothing leaves no entry", ctx do
      before = entries()
      name = ctx.scope.workspace.name
      assert {:ok, _} = Organisations.update_workspace(ctx.scope, %{name: name})
      assert {:ok, _} = Retention.update_retention(ctx.scope, %{})
      assert entries() -- before == []
    end
  end

  describe "from where" do
    test "a request's address and client, cut to the lengths kept" do
      %{scope: scope} = sign_up_fixture()
      agent = String.duplicate("a", 400)
      scope = Scope.put_origin(scope, %{remote_ip: "203.0.113.7", user_agent: agent})

      {:ok, _} = Organisations.update_workspace(scope, %{name: "Renamed"})

      assert %Entry{remote_ip: "203.0.113.7", user_agent: kept, worker: nil} = last()
      assert kept == String.slice(agent, 0, 255)
    end

    test "a job's worker" do
      %{organisation: organisation} = sign_up_fixture()
      old!(organisation)

      assert :ok =
               perform_job(Apiary.Audit.PruneJob, %{
                 "organisation_id" => organisation.id,
                 "workspace_id" => nil
               })

      assert %Entry{worker: "Apiary.Audit.PruneJob", actor_kind: :instance} = last()
    end
  end

  describe "before and after" do
    test "an edit keeps the changed fields, as they were and are" do
      %{scope: scope} = sign_up_fixture()
      {:ok, _} = Retention.update_retention(scope, %{events_retention_days: 30})

      assert %Entry{
               before: %{"events_retention_days" => nil},
               after: %{"events_retention_days" => 30},
               workspace_id: workspace_id
             } = last()

      assert workspace_id == scope.workspace.id

      {:ok, _} = Organisations.update_organisation(scope, %{name: "Acme"})
      assert %Entry{after: %{"name" => "Acme"}, workspace_id: nil} = last()
    end

    test "a membership's entries are the organisation's" do
      %{scope: scope} = sign_up_fixture()
      %{membership: membership} = member_fixture(scope)

      {:ok, _} = Organisations.set_member_level(scope, membership.id, :admin)
      assert %Entry{action: "member.change_level", workspace_id: nil} = last()
    end

    test "a member's entries name them by id" do
      %{scope: scope} = sign_up_fixture()
      %{membership: membership, user: user} = member_fixture(scope)

      {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)

      assert %Entry{
               before: %{"level" => "member"},
               after: %{"level" => "owner"},
               details: %{"user_id" => user_id}
             } = last()

      assert user_id == user.id
    end
  end

  describe "reading the trail" do
    test "an owner reads their organisation's entries, newest first, and no other's" do
      %{scope: scope} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      {:ok, _} = Organisations.update_workspace(scope, %{name: "First"})
      {:ok, _} = Organisations.update_workspace(scope, %{name: "Second"})
      {:ok, _} = Organisations.update_workspace(other, %{name: "Elsewhere"})

      assert {:ok, %{entries: [second, first, created], more?: false, page: 1}} =
               Audit.list_entries(scope)

      assert second.after == %{"name" => "Second"}
      assert first.after == %{"name" => "First"}
      assert created.action == "organisation.create"
      assert Enum.all?([second, first, created], &(&1.organisation_id == scope.organisation.id))

      assert {:ok, %{entries: [only]}} =
               Audit.list_entries(scope, %{action: "organisation.create"})

      assert only.id == created.id

      assert {:ok, %{entries: [_, _]}} =
               Audit.list_entries(scope, workspace_id: scope.workspace.id)

      # Another organisation's workspace names none of these.
      assert {:ok, %{entries: []}} = Audit.list_entries(scope, workspace_id: other.workspace.id)
    end

    test "a member may not read it" do
      %{scope: scope} = sign_up_fixture()
      %{scope: member} = member_fixture(scope)
      assert Audit.list_entries(member) == {:error, :forbidden}
    end

    test "names are looked up as they are now, within the organisation" do
      %{scope: scope, user: user} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)
      {:ok, %{entries: entries}} = Audit.list_entries(scope)

      names = Audit.names(scope, entries)
      assert names.users[user.id] == user.email
      assert names.access_keys[key.id] == %{label: key.label, key_id: key.key_id}
      assert names.workspaces[scope.workspace.id] == scope.workspace.name

      %{scope: other} = sign_up_fixture()
      assert Audit.names(other, entries).access_keys == %{}
      assert Audit.names(other, entries).workspaces == %{}
    end

    test "another organisation an entry names by id, under a key that ends in _id, is named as it is now" do
      %{scope: scope, user: user} = sign_up_fixture()
      %{organisation: first, scope: first_owner} = sign_up_fixture()
      [second, third, unnamed] = for _ <- 1..3, do: organisation_fixture()

      # No change of the core concerns two organisations: the entry is one an edition could
      # write, as the trail gives it back, in `details`, `before` and `after`. A key that
      # does not end in `_id`, and an id of no organisation, a person's among them, name
      # none.
      entry = %Entry{
        organisation_id: scope.organisation.id,
        action: "organisation.rename",
        actor_kind: :person,
        actor_id: user.id,
        subject_kind: "organisation",
        subject_id: scope.organisation.id,
        before: %{"from_id" => first.id},
        after: %{"to_id" => second.id},
        details: %{
          "party_id" => third.id,
          "party" => unnamed.id,
          "gone_id" => Ecto.UUID.generate(),
          "user_id" => user.id
        }
      }

      assert Audit.names(scope, [entry]).organisations == %{
               first.id => first.name,
               second.id => second.name,
               third.id => third.name
             }

      {:ok, _} = Organisations.update_organisation(first_owner, %{name: "Renamed"})
      assert Audit.names(scope, [entry]).organisations[first.id] == "Renamed"
    end
  end

  describe "retention" do
    test "prunes what is older than the period, records it, and leaves the rest" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{organisation: other} = sign_up_fixture()
      old = old!(organisation)
      other_old = old!(other)
      kept = Enum.map(entries(), & &1.id) -- [old.id, other_old.id]

      assert {:ok, 1} = Audit.prune(Scope.for_instance(organisation))

      ids = Enum.map(entries(), & &1.id)
      refute old.id in ids
      assert other_old.id in ids
      assert Enum.all?(kept, &(&1 in ids))

      assert %Entry{
               action: "audit.prune",
               actor_kind: :instance,
               actor_id: nil,
               subject_kind: "organisation",
               workspace_id: nil,
               details: %{"removed" => 1, "retention_days" => 90}
             } = last()

      # Nothing more to prune, nothing recorded.
      count = length(entries())
      assert {:ok, 0} = Audit.prune(Scope.for_instance(organisation))
      assert length(entries()) == count

      # Only the instance prunes.
      old!(organisation)
      assert {:error, :forbidden} = Audit.prune(scope)
    end

    test "clears the address and the client of entries older than their period, and keeps the rest" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      origin = %{remote_ip: "203.0.113.7", user_agent: "Browser/1.0"}

      {:ok, _} = Organisations.update_workspace(Scope.put_origin(scope, origin), %{name: "A"})
      recent = last()
      {:ok, _} = Organisations.update_workspace(Scope.put_origin(scope, origin), %{name: "B"})
      old = last()
      {:ok, _} = Organisations.update_workspace(Scope.put_origin(other, origin), %{name: "C"})
      elsewhere = last()

      at = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)

      for entry <- [old, elsewhere] do
        Repo.query!("UPDATE audit_entries SET inserted_at = $1 WHERE id = $2", [
          at,
          Ecto.UUID.dump!(entry.id)
        ])
      end

      count = length(entries())
      assert {:ok, 0} = Audit.prune(Scope.for_instance(organisation), address_days: 30)

      assert %Entry{remote_ip: nil, user_agent: nil, after: %{"name" => "B"}} =
               Repo.get!(Entry, old.id)

      assert %Entry{remote_ip: "203.0.113.7", user_agent: "Browser/1.0"} =
               Repo.get!(Entry, recent.id)

      assert %Entry{remote_ip: "203.0.113.7"} = Repo.get!(Entry, elsewhere.id)
      # Clearing alone is no entry.
      assert length(entries()) == count

      # A prune that deletes says how many addresses it cleared beside.
      old!(organisation)
      {:ok, _} = Organisations.update_workspace(Scope.put_origin(scope, origin), %{name: "D"})

      Repo.query!("UPDATE audit_entries SET inserted_at = $1 WHERE id = $2", [
        at,
        Ecto.UUID.dump!(last().id)
      ])

      assert {:ok, 1} = Audit.prune(Scope.for_instance(organisation), address_days: 30)

      assert %Entry{
               action: "audit.prune",
               details: %{
                 "removed" => 1,
                 "addresses_cleared" => 1,
                 "address_retention_days" => 30
               }
             } = last()
    end

    test "the sweep enqueues a prune per organisation, and a prune runs as the instance" do
      first = sign_up_fixture()
      second = sign_up_fixture()

      assert :ok = perform_job(Apiary.Audit.PruneSweep, %{})

      for %{organisation: organisation} <- [first, second] do
        assert_enqueued(
          worker: Apiary.Audit.PruneJob,
          args: %{"organisation_id" => organisation.id, "workspace_id" => nil}
        )
      end

      # A sweep run again enqueues nothing more while those wait.
      assert :ok = perform_job(Apiary.Audit.PruneSweep, %{})

      assert length(all_enqueued(worker: Apiary.Audit.PruneJob)) ==
               Repo.aggregate(Apiary.Organisations.Organisation, :count)

      old!(first.organisation)

      assert :ok =
               perform_job(Apiary.Audit.PruneJob, %{
                 "organisation_id" => first.organisation.id,
                 "workspace_id" => nil
               })

      assert %Entry{action: "audit.prune", actor_kind: :instance} = last()
    end

    test "the sweep is in the crontab, once a day" do
      crontab = Application.get_env(:apiary, Oban)[:crontab]

      assert {expression, Apiary.Audit.PruneSweep} =
               List.keyfind(crontab, Apiary.Audit.PruneSweep, 1)

      assert {:ok, _} = Oban.Cron.Expression.parse(expression)
    end

    test "AUDIT_RETENTION_DAYS: 90 when unset, a number of days from 30 to the edition's ceiling" do
      assert Apiary.Edition.audit_retention_max_days() == 90
      assert Audit.parse_retention_days(nil) == {:ok, 90}
      assert Audit.parse_retention_days("  ") == {:ok, 90}
      assert Audit.parse_retention_days("30") == {:ok, 30}
      assert Audit.parse_retention_days(" 90 ") == {:ok, 90}

      for value <- ["29", "91", "365", "2555", "0", "-5", "a year", "60.5", "1e2"] do
        assert {:error, reason} = Audit.parse_retention_days(value)
        assert reason =~ "30 to 90"
        # Above the ceiling says it is the edition's.
        assert reason =~ "90 days is the most this edition keeps"
      end
    end

    test "AUDIT_ADDRESS_RETENTION_DAYS: 90 when unset, from 1 to the trail's period" do
      assert Audit.parse_address_retention_days(nil, 90) == {:ok, 90}
      assert Audit.parse_address_retention_days("", 90) == {:ok, 90}
      assert Audit.parse_address_retention_days("1", 90) == {:ok, 1}
      assert Audit.parse_address_retention_days("90", 90) == {:ok, 90}

      # Unset, it is never longer than a shorter trail.
      assert Audit.parse_address_retention_days(nil, 45) == {:ok, 45}

      for value <- ["0", "91", "a month"] do
        assert {:error, reason} = Audit.parse_address_retention_days(value, 90)
        assert reason =~ "from 1 to 90"
        assert reason =~ "AUDIT_RETENTION_DAYS"
      end
    end

    test "a value refused stops the boot" do
      keys = ~w(audit_retention_setting audit_retention_days audit_address_retention_setting
                audit_address_retention_days)a

      previous = Map.new(keys, &{&1, Application.get_env(:apiary, &1)})

      on_exit(fn ->
        for {key, value} <- previous, do: Application.put_env(:apiary, key, value)
      end)

      Application.put_env(:apiary, :audit_address_retention_setting, nil)

      Application.put_env(:apiary, :audit_retention_setting, "20")
      assert_raise ArgumentError, ~r/AUDIT_RETENTION_DAYS/, fn -> Audit.boot!() end

      # Above the ceiling stops the boot, and the ceiling is said.
      Application.put_env(:apiary, :audit_retention_setting, "365")
      error = assert_raise ArgumentError, fn -> Audit.boot!() end
      assert error.message =~ "AUDIT_RETENTION_DAYS"
      assert error.message =~ "90 days is the most this edition keeps"

      Application.put_env(:apiary, :audit_retention_setting, "60")
      assert Audit.boot!() == 60
      assert Audit.retention_days() == 60
      assert Audit.address_retention_days() == 60

      # An address kept longer than its entry is refused, and the bound is said.
      Application.put_env(:apiary, :audit_address_retention_setting, "80")

      error = assert_raise ArgumentError, fn -> Audit.boot!() end
      assert error.message =~ "AUDIT_ADDRESS_RETENTION_DAYS"
      assert error.message =~ "from 1 to 60"

      Application.put_env(:apiary, :audit_address_retention_setting, "14")
      assert Audit.boot!() == 60
      assert Audit.address_retention_days() == 14
    end

    test "the subjects are the core's and the edition's, each named once" do
      kinds = Audit.subject_kinds()
      assert kinds[Apiary.Organisations.Workspace] == "workspace"

      for {schema, kind} <- Apiary.Edition.subject_kinds() do
        assert kinds[schema] == kind
      end

      core = %{Apiary.Organisations.Workspace => "workspace"}

      assert_raise ArgumentError, ~r/core's subject or the edition's, not both/, fn ->
        Audit.subject_kinds(core, %{Apiary.Organisations.Workspace => "space"})
      end

      assert_raise ArgumentError, ~r/named once, got twice: workspace/, fn ->
        Audit.subject_kinds(core, %{Apiary.Runs.Run => "workspace"})
      end
    end
  end

  ## Helpers

  # The relay takes the message and times out after, running `:during_delivery` first.
  defp relay_that_times_out do
    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.DeliveryMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
  end

  defp invite(scope) do
    Organisations.invite_member(
      scope,
      %{"email" => unique_user_email()},
      fn token ->
        Process.put(:invitation_token, token)
        "http://localhost/invitations/#{token}"
      end
    )
  end

  defp revoke_pending(scope) do
    [invitation] = Organisations.list_invitations(scope)
    Organisations.revoke_invitation(scope, invitation.id)
  end

  defp expire!(invitation, days_ago) do
    Repo.update_all(from(i in Apiary.Organisations.Invitation, where: i.id == ^invitation.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)]
    )
  end
end

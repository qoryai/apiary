defmodule Apiary.AuditTest do
  # Not async: the rows are asked on an instance with every feature, which is the node's.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [unique_user_email: 0, valid_user_attributes: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{Access, AccessKeys, Audit, Features, Organisations, Policy, Retention, Runs}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry

  @moduletag with_features: Features.all()

  # Every action of `Apiary.Access` is audited unless `Apiary.Audit.not_audited/0` says
  # why not (`Apiary.Audit.audited?/1`, which the Activity page's filter asks too). Each
  # test below makes the change of every audited action and finds exactly one entry of it:
  # an audited action without a `make/2` below fails there.
  @audited Audit.audited_actions()

  test "every action is audited, or says why it is not" do
    for {action, reason} <- Audit.not_audited() do
      assert action in Access.actions(), "#{action} is not an action of Apiary.Access"
      assert is_binary(reason) and reason != ""
      refute Audit.audited?(action)
    end

    for action <- Access.actions() do
      assert Audit.audited?(action) or Keyword.has_key?(Audit.not_audited(), action)
    end

    refute Audit.audited?(:"no.such_action")
  end

  test "the application has no way to change or delete an entry but the prune" do
    functions = Keyword.keys(Audit.__info__(:functions))

    for name <- functions, text = Atom.to_string(name) do
      refute text =~ ~r/update|delete|change_|edit|put/, "Apiary.Audit.#{name}"
    end

    assert :prune in functions
  end

  describe "each change" do
    setup do
      owner = sign_up_fixture()
      %{owner: owner, scope: owner.scope}
    end

    for action <- @audited do
      @tag action: action
      test "#{action} leaves exactly one entry, with no personal data or secret", ctx do
        %{action: action} = ctx

        # Each change sets up what it needs, reads the trail, and makes the change.
        %{scope: scope, subject: subject, before: before} = expected = make(action, ctx)

        assert [entry] = entries() -- before
        assert entry.action == Atom.to_string(action)
        assert Audit.action(entry) == action
        assert entry.organisation_id == organisation_id(scope)
        assert {entry.subject_kind, entry.subject_id} == subject
        assert %DateTime{} = entry.inserted_at

        case expected do
          %{actor: :instance} -> assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
          _person -> assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
        end

        refute_personal(entry, expected[:secret])
      end
    end
  end

  describe "a change that is refused or rolled back" do
    setup do
      owner = sign_up_fixture()
      %{owner: owner, scope: owner.scope}
    end

    for action <- @audited do
      @tag action: action
      test "#{action} refused leaves no entry", ctx do
        assert {before, {:error, _reason}} = refuse(ctx.action, ctx)
        assert entries() -- before == []
      end
    end

    test "an invitation that could not be delivered is withdrawn, and the trail says so",
         ctx do
      previous = Application.fetch_env!(:apiary, Apiary.Mailer)
      Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
      before = entries()

      assert {:error, :delivery_failed} =
               Organisations.invite_member(
                 ctx.scope,
                 %{"email" => unique_user_email(), "level" => "member"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert [invited, withdrawn] = entries() -- before
      assert %Entry{action: "member.invite", subject_kind: "invitation"} = invited

      assert %Entry{
               action: "invitation.revoke",
               before: %{"level" => "member"},
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

      assert Repo.get!(Apiary.Organisations.Invitation, invitation.id).accepted_at
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
               details: %{"removed" => 1, "retention_days" => 365}
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

    test "AUDIT_RETENTION_DAYS: 365 when unset, a number of days from 90 to 2555" do
      assert Audit.parse_retention_days(nil) == {:ok, 365}
      assert Audit.parse_retention_days("  ") == {:ok, 365}
      assert Audit.parse_retention_days("90") == {:ok, 90}
      assert Audit.parse_retention_days(" 2555 ") == {:ok, 2555}

      for value <- ["89", "2556", "0", "-5", "a year", "365.5", "1e3"] do
        assert {:error, reason} = Audit.parse_retention_days(value)
        assert reason =~ "90 to 2555"
      end
    end

    test "AUDIT_ADDRESS_RETENTION_DAYS: 90 when unset, from 1 to the trail's period" do
      assert Audit.parse_address_retention_days(nil, 365) == {:ok, 90}
      assert Audit.parse_address_retention_days("", 365) == {:ok, 90}
      assert Audit.parse_address_retention_days("1", 365) == {:ok, 1}
      assert Audit.parse_address_retention_days("365", 365) == {:ok, 365}

      for value <- ["0", "366", "a month"] do
        assert {:error, reason} = Audit.parse_address_retention_days(value, 365)
        assert reason =~ "from 1 to 365"
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

      Application.put_env(:apiary, :audit_retention_setting, "30")
      assert_raise ArgumentError, ~r/AUDIT_RETENTION_DAYS/, fn -> Audit.boot!() end

      Application.put_env(:apiary, :audit_retention_setting, "730")
      assert Audit.boot!() == 730
      assert Audit.retention_days() == 730
      assert Audit.address_retention_days() == 90

      # An address kept longer than its entry is refused, and the bound is said.
      Application.put_env(:apiary, :audit_retention_setting, "120")
      Application.put_env(:apiary, :audit_address_retention_setting, "180")

      error = assert_raise ArgumentError, fn -> Audit.boot!() end
      assert error.message =~ "AUDIT_ADDRESS_RETENTION_DAYS"
      assert error.message =~ "from 1 to 120"

      Application.put_env(:apiary, :audit_address_retention_setting, "14")
      assert Audit.boot!() == 120
      assert Audit.address_retention_days() == 14
    end
  end

  ## The changes, each made the way the product makes it: what it needs first, then the
  ## trail as it is (`before`), then the change

  defp make(:"organisation.create", _ctx) do
    before = entries()

    {:ok, %{user: user, organisation: organisation} = signed_up} =
      Organisations.sign_up_user(valid_user_attributes(%{}))

    scope = %Scope{user: user, organisation: organisation, workspace: signed_up.workspace}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  defp make(:"organisation.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_organisation(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  defp make(:"member.invite", %{scope: scope}) do
    before = entries()
    %{invitation: invitation} = invitation_fixture(scope)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  defp make(:"member.change_level", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  defp make(:"member.remove", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.remove_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  defp make(:"invitation.revoke", %{scope: scope}) do
    %{invitation: invitation} = invitation_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.revoke_invitation(scope, invitation.id)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  defp make(:"invitation.accept", %{scope: scope}) do
    %{invitation: invitation, token: token} = invitation_fixture(scope)
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, _membership} = Organisations.accept_invitation(Scope.for_user(user), token)
    accepted = %Scope{user: user, organisation: scope.organisation}
    %{scope: accepted, subject: {"invitation", invitation.id}, before: before}
  end

  defp make(:"audit.prune", %{owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    instance = Scope.for_instance(organisation)
    {:ok, 1} = Audit.prune(instance)
    # The pruned entry is gone from the trail: it is not the one looked for.
    %{
      scope: instance,
      actor: :instance,
      subject: {"organisation", organisation.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  defp make(:"workspace.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_workspace(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  defp make(:"access_key.create", %{scope: scope}) do
    before = entries()
    {:ok, key, secret} = AccessKeys.create_access_key(scope, %{label: "build-01"})
    %{scope: scope, subject: {"access_key", key.id}, secret: secret, before: before}
  end

  defp make(:"access_key.rotate", %{scope: scope}) do
    %{access_key: key} = access_key_fixture(scope)
    before = entries()
    {:ok, key, secret} = AccessKeys.rotate_access_key(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, secret: secret, before: before}
  end

  defp make(:"access_key.revoke", %{scope: scope}) do
    %{access_key: key} = access_key_fixture(scope)
    before = entries()
    {:ok, _} = AccessKeys.revoke_access_key(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  defp make(:"run.close", %{scope: scope}) do
    run = run_fixture(scope)
    before = entries()
    {:ok, _} = Runs.close_run(scope, run)
    %{scope: scope, subject: {"run", run.id}, before: before}
  end

  defp make(:"retention.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Retention.update_retention(scope, %{events_retention_days: 30})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  defp make(:"security_policy.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  defp make(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    before = entries()
    {:ok, _} = Policy.lock(scope, rule)
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  defp make(:"security_policy.set_mode", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.set_mode(scope, "enforce")
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  ## The same changes, refused: `{the trail before the attempt, the attempt's answer}`

  defp refuse(:"organisation.create", _ctx) do
    before = entries()
    {before, Organisations.sign_up_user(%{email: "not an address", organisation_name: "Acme"})}
  end

  defp refuse(:"invitation.accept", %{scope: scope}) do
    %{token: token} = invitation_fixture(scope)
    # Accepted once already: the second finds no pending invitation.
    %{user: first} = sign_up_fixture()
    {:ok, _} = Organisations.accept_invitation(first, token)
    %{user: user} = sign_up_fixture()
    before = entries()
    {before, Organisations.accept_invitation(Scope.for_user(user), token)}
  end

  defp refuse(:"audit.prune", %{scope: scope, owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    {before, Audit.prune(scope)}
  end

  # A member where the change is an owner's; where every member may make it, a person who
  # was a member when the scope was loaded and is no longer.
  defp refuse(action, %{scope: scope} = ctx) do
    %{scope: member, membership: membership} = member_fixture(scope)
    prepared = prepare(action, ctx)

    if action in Access.roles().member,
      do: {:ok, _} = Organisations.remove_member(scope, membership.id)

    before = entries()
    {before, attempt(action, member, prepared)}
  end

  defp prepare(:"member.change_level", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"member.remove", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"invitation.revoke", %{scope: scope}), do: invitation_fixture(scope).invitation
  defp prepare(:"access_key.rotate", %{scope: scope}), do: access_key_fixture(scope).access_key
  defp prepare(:"access_key.revoke", %{scope: scope}), do: access_key_fixture(scope).access_key
  defp prepare(:"run.close", %{scope: scope}), do: run_fixture(scope)

  defp prepare(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    rule
  end

  defp prepare(_action, _ctx), do: nil

  defp attempt(:"organisation.rename", scope, _),
    do: Organisations.update_organisation(scope, %{name: "Renamed"})

  defp attempt(:"member.invite", scope, _) do
    Organisations.invite_member(
      scope,
      %{"email" => unique_user_email(), "level" => "member"},
      &"http://localhost/invitations/#{&1}"
    )
  end

  defp attempt(:"member.change_level", scope, membership),
    do: Organisations.set_member_level(scope, membership.id, :owner)

  defp attempt(:"member.remove", scope, membership),
    do: Organisations.remove_member(scope, membership.id)

  defp attempt(:"invitation.revoke", scope, invitation),
    do: Organisations.revoke_invitation(scope, invitation.id)

  defp attempt(:"workspace.rename", scope, _),
    do: Organisations.update_workspace(scope, %{name: "Renamed"})

  defp attempt(:"access_key.create", scope, _),
    do: AccessKeys.create_access_key(scope, %{label: "build-01"})

  defp attempt(:"access_key.rotate", scope, key), do: AccessKeys.rotate_access_key(scope, key)
  defp attempt(:"access_key.revoke", scope, key), do: AccessKeys.revoke_access_key(scope, key)
  defp attempt(:"run.close", scope, run), do: Runs.close_run(scope, run)

  defp attempt(:"retention.edit", scope, _),
    do: Retention.update_retention(scope, %{events_retention_days: 30})

  defp attempt(:"security_policy.edit", scope, _),
    do: Policy.allow(scope, nil, %{host: "api.example"})

  defp attempt(:"security_policy.lock", scope, rule), do: Policy.lock(scope, rule)
  defp attempt(:"security_policy.set_mode", scope, _), do: Policy.set_mode(scope, "enforce")

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
      %{"email" => unique_user_email(), "level" => "member"},
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

  defp entries, do: Repo.all(from e in Entry, order_by: [asc: e.inserted_at, asc: e.id])

  defp last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)

  # An entry of `organisation` older than the audit trail keeps: its creation, a year and
  # a day back.
  defp old!(organisation) do
    %Entry{} =
      entry =
      Repo.one!(
        from e in Entry,
          where: e.organisation_id == ^organisation.id,
          order_by: [asc: e.inserted_at, asc: e.id],
          limit: 1
      )

    at = DateTime.add(DateTime.utc_now(), -366 * 86_400, :second)

    Repo.query!("UPDATE audit_entries SET inserted_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(entry.id)
    ])

    entry
  end

  defp organisation_id(%Scope{organisation: %{id: id}}), do: id

  # No email address of any account, and no secret, anywhere in what the entry keeps.
  defp refute_personal(%Entry{} = entry, secret) do
    kept = Jason.encode!([entry.before, entry.after, entry.details])

    # Nor the address's local part, which a name made from it would carry.
    for email <- Repo.all(from u in User, select: u.email),
        text <- [email, email |> String.split("@") |> hd()] do
      refute kept =~ text, "the entry keeps #{text}"
    end

    refute kept =~ "@", "the entry keeps something like an email address: #{kept}"
    if secret, do: refute(kept =~ secret, "the entry keeps the secret")
  end
end

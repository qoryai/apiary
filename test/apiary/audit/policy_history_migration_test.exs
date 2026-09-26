defmodule Apiary.Audit.PolicyHistoryMigrationTest do
  @moduledoc """
  `20261003000300`: the history of the security policy, `policy_changes`, copied into the
  audit trail. Each row becomes the entry of its policy action, under its own id; the run
  configurations it rendered name the entry; the policy page reads the same history from
  the trail; copying again copies nothing more, and the rollback takes the copies away.
  """
  # Not async: the migration writes across the tables, as it runs.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  Code.require_file(
    "priv/repo/migrations/20261003000300_copy_policy_changes_into_audit_entries.exs",
    File.cwd!()
  )

  alias Apiary.Audit.Entry
  alias Apiary.Policy
  alias Apiary.Repo.Migrations.CopyPolicyChangesIntoAuditEntries, as: Migration

  @version 20_261_003_000_300

  defp dump(id), do: Ecto.UUID.dump!(id)

  # A row as the release before wrote it.
  defp policy_change!(scope, attrs) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO policy_changes (
        id, organisation_id, workspace_id, target_id, action, subject, before, after,
        version_after, changed_by_id, inserted_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        dump(id),
        dump(scope.organisation.id),
        dump(scope.workspace.id),
        attrs[:target_id] && dump(attrs[:target_id]),
        attrs.action,
        attrs[:subject],
        attrs.before,
        attrs.after,
        attrs.version_after,
        attrs[:changed_by_id] && dump(attrs[:changed_by_id]),
        attrs.at
      ]
    )

    id
  end

  defp configuration!(scope, target_id, version, change_id) do
    document = ~s({"version":1,"n":#{version},"t":"#{target_id}"})

    Repo.query!(
      """
      INSERT INTO run_configurations (
        id, organisation_id, workspace_id, target_id, version, document, digest, rendered_at,
        policy_change_id
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, now(), $8)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(scope.organisation.id),
        dump(scope.workspace.id),
        target_id && dump(target_id),
        version,
        document,
        "sha256=" <> Base.encode16(:crypto.hash(:sha256, document), case: :lower),
        dump(change_id)
      ]
    )
  end

  defp migrate(direction),
    do:
      apply(Ecto.Migrator, direction, [
        Repo,
        @version,
        Migration,
        [log: false, migration_lock: false]
      ])

  test "the history reads the same from the trail, and the copy is done once" do
    %{scope: scope, user: user} = sign_up_fixture()

    target =
      Repo.insert!(%Apiary.Runs.Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "forge.example",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

    t0 = ~U[2026-09-20 10:00:00.000000Z]
    empty = %{"mode" => "observe", "rules" => []}
    enforce = %{"mode" => "enforce", "rules" => []}

    rule = %{
      "kind" => "host",
      "action" => "allow",
      "host" => "api.example",
      "paths" => nil,
      "name" => nil,
      "argument" => nil,
      "locked" => true
    }

    mode =
      policy_change!(scope, %{
        action: "mode_changed",
        before: empty,
        after: enforce,
        version_after: 1,
        changed_by_id: user.id,
        at: t0
      })

    locked =
      policy_change!(scope, %{
        action: "rule_locked",
        subject: "api.example",
        before: %{enforce | "rules" => [%{rule | "locked" => false}]},
        after: %{enforce | "rules" => [rule]},
        version_after: 2,
        changed_by_id: user.id,
        at: DateTime.add(t0, 60)
      })

    rerendered =
      policy_change!(scope, %{
        action: "rerendered",
        target_id: target.id,
        before: %{"mode" => "inherit", "rules" => []},
        after: %{"mode" => "inherit", "rules" => []},
        version_after: 1,
        at: DateTime.add(t0, 120)
      })

    configuration!(scope, nil, 1, mode)
    configuration!(scope, nil, 2, locked)
    configuration!(scope, target.id, 1, rerendered)

    # The copy runs as a release migrates: taken back first, since it ran when the test
    # database was made, before these rows were there.
    migrate(:down)
    migrate(:up)

    entry = Repo.get!(Entry, mode)

    assert %Entry{
             action: "security_policy.set_mode",
             actor_kind: :person,
             subject_kind: "workspace",
             before: ^empty,
             after: ^enforce,
             details: %{"change" => "mode_changed", "version" => 1},
             worker: nil,
             inserted_at: ^t0
           } = entry

    assert entry.actor_id == user.id
    assert entry.subject_id == scope.workspace.id
    assert entry.organisation_id == scope.organisation.id
    assert entry.workspace_id == scope.workspace.id

    assert %Entry{action: "security_policy.lock", details: %{"subject" => "api.example"}} =
             Repo.get!(Entry, locked)

    assert %Entry{
             action: "security_policy.edit",
             actor_kind: :instance,
             actor_id: nil,
             subject_kind: "target",
             worker: "mix apiary.policy.rerender"
           } = rerendered_entry = Repo.get!(Entry, rerendered)

    assert rerendered_entry.subject_id == target.id

    # The policy page's history, from the trail: the same author, time, change and version.
    assert %{total: 2, items: [second, first]} = Policy.list_changes(scope, nil)

    assert %{id: ^locked, action: "rule_locked", subject: "api.example", version_after: 2} =
             second

    assert %{id: ^mode, action: "mode_changed", version_after: 1, inserted_at: ^t0} = first
    assert first.changed_by.email == user.email
    assert Policy.diff(first).mode == {"observe", "enforce"}

    assert %{items: [%{action: "rerendered", changed_by: nil, target_id: target_id}]} =
             Policy.list_changes(scope, target)

    assert target_id == target.id

    assert %{^mode => [%{version: 1, target_id: nil}]} =
             Policy.configurations_for_changes(scope, [mode])

    assert Policy.managed?(scope)

    # Again: nothing more.
    count = Repo.aggregate(Entry, :count)
    migrate(:down)
    migrate(:up)
    migrate(:up)
    assert Repo.aggregate(Entry, :count) == count

    # Rolled back: the copies go, and the configurations no longer name them.
    migrate(:down)
    refute Repo.get(Entry, mode)

    assert Repo.query!("SELECT count(*) FROM run_configurations WHERE audit_entry_id IS NOT NULL").rows ==
             [[0]]
  end
end

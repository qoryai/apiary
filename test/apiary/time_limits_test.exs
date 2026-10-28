defmodule Apiary.TimeLimitsTest do
  # The time limit per workflow at the workspace and at a target: what each write stores
  # and leaves in the trail, every refusal of a save, what resolves for a run, and a
  # purge. The resolution itself is `test/apiary/time_limits/resolution_test.exs`; the
  # handover's member and the feature off are
  # `test/apiary/dispatches/run_settings_time_limit_test.exs`.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures, only: [target!: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Deletion, TimeLimits}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Workspace
  alias Apiary.TimeLimits.{Resolution, TimeLimit}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, target: target!(scope, "acme/shop")}
  end

  defp trail(id),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp errors(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  describe "a write at each place" do
    test "stores one limit at the workspace and one at a target, each with its entry", ctx do
      %{scope: scope, target: target} = ctx

      for {holder, level, name} <- [
            {:workspace, :workspace, scope.workspace.name},
            {target, :target, "github.example/acme/shop"}
          ] do
        assert {:ok, %TimeLimit{} = limit} =
                 TimeLimits.put_limit(scope, holder, "hello", 90)

        assert TimeLimit.level(limit) == level
        assert {limit.workflow, limit.minutes} == {"hello", 90}
        assert limit.workspace_id == scope.workspace.id
        assert limit.created_by_id == scope.user.id

        assert [entry] = trail(limit.id)
        assert entry.action == "time_limit.edit"
        assert entry.subject_kind == "time_limit"
        assert entry.details["change"] == "time_limit_set"
        assert entry.details["workflow"] == "hello"
        assert entry.details["name"] == name
        assert entry.before == nil
        assert entry.after == %{"minutes" => 90}
      end

      assert [%{details: details}] =
               Repo.all(from e in Entry, where: e.details["target_id"] == ^target.id)

      assert details["target_id"] == target.id
      assert {:ok, limits} = TimeLimits.list_limits(scope)
      assert length(limits) == 2
    end

    test "changes the limit it has, with the minutes before and after", %{scope: scope} do
      {:ok, first} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
      assert {:ok, changed} = TimeLimits.put_limit(scope, :workspace, "hello", 240)

      assert changed.id == first.id
      assert changed.minutes == 240
      assert Repo.aggregate(TimeLimit, :count) == 1

      assert [_set, entry] = trail(first.id)
      assert entry.details["change"] == "time_limit_changed"
      assert entry.before == %{"minutes" => 90}
      assert entry.after == %{"minutes" => 240}
    end

    test "leaves no entry for a save that changes nothing", %{scope: scope} do
      {:ok, first} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
      assert {:ok, same} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
      assert same.id == first.id
      assert length(trail(first.id)) == 1
    end

    test "keeps one limit per workflow at a place", %{scope: scope} do
      {:ok, _hello} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
      {:ok, _review} = TimeLimits.put_limit(scope, :workspace, "review", 30)
      assert Repo.aggregate(TimeLimit, :count) == 2
    end

    test "takes the minutes of a form, as a string", %{scope: scope} do
      assert {:ok, %TimeLimit{minutes: 45}} =
               TimeLimits.put_limit(scope, :workspace, "hello", "45")
    end

    test "removes a limit with its entry, and finds none to remove twice", %{scope: scope} do
      {:ok, limit} = TimeLimits.put_limit(scope, :workspace, "hello", 90)

      assert {:ok, %TimeLimit{id: id}} =
               TimeLimits.delete_limit(scope, :workspace, "hello")

      assert id == limit.id
      assert Repo.aggregate(TimeLimit, :count) == 0

      assert [_set, entry] = trail(limit.id)
      assert entry.details["change"] == "time_limit_removed"
      assert entry.before == %{"minutes" => 90}
      assert entry.after == nil

      assert TimeLimits.delete_limit(scope, :workspace, "hello") == {:error, :not_found}
    end

    test "a target of another workspace is not found", %{scope: scope, target: target} do
      other = workspace_fixture(scope.organisation, "Other site")

      foreign =
        Repo.insert!(%Apiary.Runs.Target{
          organisation_id: scope.organisation.id,
          workspace_id: other.id,
          system: "github.example",
          path: "acme/other",
          first_seen_at: DateTime.utc_now()
        })

      assert TimeLimits.put_limit(scope, foreign, "hello", 90) == {:error, :not_found}

      # A scope of another organisation reaches neither this workspace's target nor,
      # given this workspace, the workspace.
      %{scope: stranger} = sign_up_fixture()
      assert TimeLimits.put_limit(stranger, target, "hello", 90) == {:error, :not_found}
      assert TimeLimits.delete_limit(stranger, target, "hello") == {:error, :not_found}

      assert TimeLimits.put_limit(
               %{stranger | workspace: scope.workspace},
               :workspace,
               "hello",
               90
             ) ==
               {:error, :not_found}

      assert TimeLimits.resolve(scope, foreign, "hello") == {:error, :not_found}
      assert Repo.aggregate(TimeLimit, :count) == 0
    end
  end

  describe "who may write" do
    test "an owner and an admin write at the workspace and at a target, a member at neither",
         ctx do
      %{scope: scope, target: target} = ctx
      %{scope: admin} = member_fixture(scope, :admin)
      %{scope: member} = member_fixture(scope)

      for holder <- [:workspace, target] do
        assert {:error, :forbidden} = TimeLimits.put_limit(member, holder, "hello", 90)
        assert {:ok, _} = TimeLimits.put_limit(admin, holder, "hello", 90)
        assert {:ok, _} = TimeLimits.put_limit(scope, holder, "hello", 120)
        assert {:error, :forbidden} = TimeLimits.delete_limit(member, holder, "hello")
      end

      assert Repo.aggregate(TimeLimit, :count) == 2
      assert {:ok, [_, _]} = TimeLimits.list_limits(member)
    end
  end

  describe "a save is refused" do
    test "for minutes outside 15 to 1440, or not whole", %{scope: scope} do
      assert {:ok, %TimeLimit{minutes: 15}} =
               TimeLimits.put_limit(scope, :workspace, "low", 15)

      assert {:ok, %TimeLimit{minutes: 1440}} =
               TimeLimits.put_limit(scope, :workspace, "high", 1440)

      assert %{minutes: ["must be greater than or equal to 15"]} =
               errors(TimeLimits.put_limit(scope, :workspace, "hello", 14))

      assert %{minutes: ["must be less than or equal to 1440"]} =
               errors(TimeLimits.put_limit(scope, :workspace, "hello", 1441))

      assert %{minutes: ["is invalid"]} =
               errors(TimeLimits.put_limit(scope, :workspace, "hello", 90.5))

      assert %{minutes: ["can't be blank"]} =
               errors(TimeLimits.put_limit(scope, :workspace, "hello", nil))
    end

    test "for a workflow that breaks the name rule of a workflow", %{scope: scope} do
      for workflow <- ["Hello", "1hello", "hello world", String.duplicate("a", 65), ""] do
        assert %{workflow: [_reason]} =
                 errors(TimeLimits.put_limit(scope, :workspace, workflow, 90))
      end

      assert {:ok, _limit} =
               TimeLimits.put_limit(scope, :workspace, String.duplicate("a", 64), 90)
    end

    test "with nothing written and no entry", %{scope: scope} do
      {:error, _changeset} = TimeLimits.put_limit(scope, :workspace, "hello", 5)
      assert Repo.aggregate(TimeLimit, :count) == 0
      assert Repo.all(from e in Entry, where: e.subject_kind == "time_limit") == []
    end
  end

  describe "resolve/3" do
    test "takes the target's limit first, then the workspace's, then none", ctx do
      %{scope: scope, target: target} = ctx

      assert TimeLimits.resolve(scope, target, "hello") == {:ok, :none}

      {:ok, _} = TimeLimits.put_limit(scope, :workspace, "hello", 90)

      assert {:ok, {:ok, %Resolution{minutes: 90, level: :workspace}}} =
               TimeLimits.resolve(scope, target, "hello")

      {:ok, _} = TimeLimits.put_limit(scope, target, "hello", 600)

      assert {:ok, {:ok, %Resolution{minutes: 600, level: :target}}} =
               TimeLimits.resolve(scope, target, "hello")

      # The workspace alone reads no target's limit, and another workflow reads neither.
      assert {:ok, {:ok, %Resolution{minutes: 90, level: :workspace}}} =
               TimeLimits.resolve(scope, :workspace, "hello")

      assert TimeLimits.resolve(scope, target, "review") == {:ok, :none}

      # Removed at the target, the workspace's applies again.
      {:ok, _} = TimeLimits.delete_limit(scope, target, "hello")

      assert {:ok, {:ok, %Resolution{minutes: 90, level: :workspace}}} =
               TimeLimits.resolve(scope, target, "hello")
    end

    test "reads no limit of another workspace", %{scope: scope} do
      other = workspace_fixture(scope.organisation, "Other site")
      other_scope = workspace_scope(scope.user, other)
      {:ok, _} = TimeLimits.put_limit(other_scope, :workspace, "hello", 90)

      assert TimeLimits.resolve(scope, :workspace, "hello") == {:ok, :none}
    end
  end

  describe "in a workspace whose domain has no repository" do
    test "the limits hold, and no text of the module names a repository", ctx do
      scope = with_domain(ctx.scope, "example")
      target = target!(scope, "queue/billing")

      {:ok, _} = TimeLimits.put_limit(scope, target, "hello", 120)

      assert {:ok, {:ok, %Resolution{minutes: 120, level: :target}}} =
               TimeLimits.resolve(scope, target, "hello")

      for file <- ["lib/apiary/time_limits.ex" | Path.wildcard("lib/apiary/time_limits/*.ex")] do
        refute File.read!(file) =~ ~r/repositor|forge|github|\bcode\b/i, file
      end
    end
  end

  describe "a purge" do
    test "of a workspace takes its limits and its targets' limits, no other's", ctx do
      %{scope: scope} = ctx
      other = workspace_fixture(scope.organisation, "Other site")
      other_scope = workspace_scope(scope.user, other)
      other_target = target!(other_scope, "acme/other")
      {:ok, kept} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
      {:ok, _} = TimeLimits.put_limit(other_scope, :workspace, "hello", 30)
      {:ok, _} = TimeLimits.put_limit(other_scope, other_target, "hello", 600)

      {:ok, _} = Deletion.delete_workspace(scope, other.id, other.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^other.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_workspace(
                 Apiary.Accounts.Scope.for_instance(
                   scope.organisation,
                   Repo.get!(Workspace, other.id)
                 )
               )

      assert Repo.all(from l in TimeLimit, select: l.id) == [kept.id]
    end
  end
end

defmodule Apiary.HarnessesTest do
  # The instance's assignments of harness sources: who creates and deletes one, what each
  # change writes to the trail, and every refusal of a source. Not async: one test turns
  # the feature `factory` off, and the features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, Harnesses}
  alias Apiary.Audit.Entry
  alias Apiary.Harnesses.Assignment

  @moduletag needs: :factory

  @git "https://code.example.com/team/stacks"
  @root %{"git" => @git, "ref" => "v1"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, admin: instance_admin_scope()}
  end

  # The scope of `admin`, last signed in `minutes` ago: a sign-in counts as recent for 20
  # minutes (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in_minutes_ago(admin, minutes) do
    at = DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
    %{admin | user: %{admin.user | authenticated_at: at}}
  end

  defp entries(action),
    do: Repo.all(from e in Entry, where: e.action == ^action, order_by: [asc: e.inserted_at])

  # The changeset errors on `source` of assigning `source` to every organisation.
  defp refused(ctx, source) do
    assert {:error, changeset} = Harnesses.assign(ctx.admin, source, :every)
    refute Repo.exists?(Assignment)
    errors_on(changeset)[:source]
  end

  describe "assign/3" do
    test "an instance admin assigns a source to one organisation, in the instance's trail",
         ctx do
      assert {:ok, %Assignment{} = assignment} =
               Harnesses.assign(ctx.admin, @root, ctx.scope.organisation)

      assert assignment.organisation_id == ctx.scope.organisation.id
      refute assignment.every_organisation
      assert assignment.source == @root
      assert assignment.created_by_id == ctx.admin.user.id

      assert [entry] = entries("harness.assigned")
      assert entry.organisation_id == Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"harness_assignment", assignment.id}
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.admin.user.id}

      assert entry.after == %{
               "source" => @root,
               "organisation_id" => ctx.scope.organisation.id,
               "every_organisation" => false
             }
    end

    test "an instance admin assigns a source to every organisation", ctx do
      assert {:ok, assignment} = Harnesses.assign(ctx.admin, @root, :every)
      assert assignment.organisation_id == nil
      assert assignment.every_organisation
      assert [%Entry{after: %{"every_organisation" => true}}] = entries("harness.assigned")
    end

    test "an instance admin acting in another organisation records in the instance's trail",
         ctx do
      admin = %{ctx.admin | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}
      assert {:ok, _assignment} = Harnesses.assign(admin, @root, ctx.scope.organisation)
      assert [entry] = entries("harness.assigned")
      assert entry.organisation_id == Edition.instance_organisation_id()
    end

    test "takes a root, a folder, an export and a module", ctx do
      for source <- [
            @root,
            Map.put(@root, "path", "stacks/web"),
            Map.put(@root, "stack", "web"),
            Map.put(@root, "module", "lint"),
            %{"git" => "https://code.example.com:8443/team/modules.git", "ref" => "abc123"}
          ] do
        assert {:ok, %Assignment{source: ^source}} = Harnesses.assign(ctx.admin, source, :every)
      end
    end

    test "refuses anyone but an instance admin, and writes nothing", ctx do
      %{scope: member} = member_fixture(ctx.scope)

      for scope <- [ctx.scope, member, instance_scope(), nil] do
        assert Harnesses.assign(scope, @root, :every) == {:error, :forbidden}
      end

      refute Repo.exists?(Assignment)
      assert entries("harness.assigned") == []
    end

    test "refuses an instance admin who did not sign in recently, until they do", ctx do
      stale = signed_in_minutes_ago(ctx.admin, 21)
      assert Harnesses.assign(stale, @root, :every) == {:error, :sudo}
      refute Repo.exists?(Assignment)
      assert entries("harness.assigned") == []

      recent = signed_in_minutes_ago(ctx.admin, 19)
      assert {:ok, _assignment} = Harnesses.assign(recent, @root, :every)
    end

    test "is not found where the feature factory is off, for an instance admin too", ctx do
      previous = Application.get_env(:apiary, :features)
      {:ok, features} = Apiary.Features.parse("observability,security")
      Application.put_env(:apiary, :features, features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

      assert Harnesses.assign(ctx.admin, @root, :every) == {:error, :not_found}
      refute Repo.exists?(Assignment)
    end

    test "refuses a second assignment of a source to one organisation", ctx do
      assert {:ok, _} = Harnesses.assign(ctx.admin, @root, ctx.scope.organisation)

      assert {:error, changeset} = Harnesses.assign(ctx.admin, @root, ctx.scope.organisation)
      assert errors_on(changeset)[:source] == ["has already been taken"]

      assert {:ok, _} = Harnesses.assign(ctx.admin, @root, :every)
      assert {:error, changeset} = Harnesses.assign(ctx.admin, @root, :every)
      assert errors_on(changeset)[:source] == ["has already been taken"]

      %{scope: other} = sign_up_fixture()
      assert {:ok, _} = Harnesses.assign(ctx.admin, @root, other.organisation)
      assert {:ok, _} = Harnesses.assign(ctx.admin, Map.put(@root, "ref", "v2"), :every)
      assert Repo.aggregate(Assignment, :count) == 4
    end

    test "refuses an address that is not https, or that has a credential, query or fragment",
         ctx do
      assert [message] = refused(ctx, %{@root | "git" => "http://code.example.com/team/s"})
      assert message =~ "as an https address"

      assert [message] =
               refused(ctx, %{@root | "git" => "https://someone:secret@code.example.com/s"})

      assert message =~ "remove the user name and password"
      refute message =~ "secret"

      assert [message] = refused(ctx, %{@root | "git" => "https://code.example.com/s?x=1"})
      assert message =~ "with no query (?) and no fragment (#)"
    end

    test "refuses a source the harness format refuses", ctx do
      for source <- [
            Map.merge(@root, %{"path" => "stacks/web", "stack" => "web"}),
            Map.merge(@root, %{"path" => "modules/lint", "module" => "lint"}),
            Map.merge(@root, %{"stack" => "web", "module" => "lint"}),
            Map.delete(@root, "ref"),
            Map.delete(@root, "git"),
            Map.put(@root, "stack", "../web")
          ] do
        assert [message] = refused(ctx, source), inspect(source)
        assert message =~ "does not follow the harness format", inspect(source)
      end
    end

    test "refuses a key that is no source key, a value that is not text, and no map", ctx do
      for source <- [
            Map.put(@root, "variant", "x"),
            Map.put(@root, "ref", 7),
            %{git: @git, ref: "v1"},
            "#{@git}#v1"
          ] do
        assert refused(ctx, source) == ["is invalid"], inspect(source)
      end
    end
  end

  describe "unassign/2" do
    setup ctx do
      {:ok, assignment} = Harnesses.assign(ctx.admin, @root, ctx.scope.organisation)
      %{assignment: assignment}
    end

    test "an instance admin deletes an assignment, in the instance's trail", ctx do
      assert {:ok, deleted} = Harnesses.unassign(ctx.admin, ctx.assignment)
      assert deleted.id == ctx.assignment.id
      refute Repo.exists?(Assignment)

      assert [entry] = entries("harness.unassigned")
      assert entry.organisation_id == Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"harness_assignment", deleted.id}

      assert entry.before == %{
               "source" => @root,
               "organisation_id" => ctx.scope.organisation.id,
               "every_organisation" => false
             }
    end

    test "is not found for an assignment deleted already", ctx do
      assert {:ok, _} = Harnesses.unassign(ctx.admin, ctx.assignment)
      assert Harnesses.unassign(ctx.admin, ctx.assignment) == {:error, :not_found}
      assert length(entries("harness.unassigned")) == 1
    end

    test "refuses an instance admin who did not sign in recently, until they do", ctx do
      stale = signed_in_minutes_ago(ctx.admin, 21)
      assert Harnesses.unassign(stale, ctx.assignment) == {:error, :sudo}
      assert Repo.exists?(Assignment)
      assert entries("harness.unassigned") == []

      recent = signed_in_minutes_ago(ctx.admin, 19)
      assert {:ok, _deleted} = Harnesses.unassign(recent, ctx.assignment)
    end

    test "refuses anyone but an instance admin, and deletes nothing", ctx do
      assert Harnesses.unassign(ctx.scope, ctx.assignment) == {:error, :forbidden}
      assert Repo.exists?(Assignment)
      assert entries("harness.unassigned") == []
    end
  end

  describe "the table" do
    test "keeps every_organisation in step with organisation_id", ctx do
      for {organisation_id, every} <- [{ctx.scope.organisation.id, true}, {nil, false}] do
        assert_raise Ecto.ConstraintError, ~r/harness_assignments_every_organisation/, fn ->
          Repo.transact(fn ->
            Repo.insert!(%Assignment{
              organisation_id: organisation_id,
              every_organisation: every,
              source: @root
            })

            {:ok, nil}
          end)
        end
      end
    end

    test "refuses a source without a text git and ref", _ctx do
      for source <- [%{"git" => @git}, %{"git" => @git, "ref" => 7}, %{"ref" => "v1"}] do
        assert_raise Ecto.ConstraintError, ~r/harness_assignments_source_shape/, fn ->
          Repo.transact(fn ->
            {:ok, Repo.insert!(%Assignment{every_organisation: true, source: source})}
          end)
        end
      end
    end
  end
end

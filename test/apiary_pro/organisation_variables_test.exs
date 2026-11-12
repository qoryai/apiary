defmodule ApiaryPro.OrganisationVariablesTest do
  # The organisation's variables, the level above its workspaces' variables: who reads and
  # changes them, the core's checks of a name and a value, the checks across the
  # workspaces, the trail, the counts of what the workspaces set themselves, and what the
  # core resolves them as.
  # Not async: the instance's features are the node's, and every test here asks on an
  # instance with all of them, or without the feature.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Organisations, Variables}
  alias Apiary.Audit.Entry
  alias Apiary.Runs.Target
  alias Apiary.Variables.Resolution
  alias ApiaryPro.OrganisationVariables
  alias ApiaryPro.OrganisationVariables.Variable

  @moduletag with_features: Features.all()
  # The organisation's variables need `secrets`: they run only where both are on.
  @moduletag needs: :organisation_variables

  setup do
    %{scope: owner, organisation: organisation, workspace: main} = sign_up_fixture()
    platform = workspace_fixture(organisation, "Platform")

    %{
      owner: owner,
      organisation: organisation,
      main: main,
      platform: platform,
      admin: member_fixture(owner, :admin).scope,
      member: member_fixture(owner, :member).scope
    }
  end

  defp entries(organisation) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation.id,
        where: e.action == "organisation_variable.edit",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp target!(%{id: workspace_id, organisation_id: organisation_id}, path) do
    Repo.insert!(%Target{
      organisation_id: organisation_id,
      workspace_id: workspace_id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  # A workspace's or a repository's own variables, written as rows, so a test can set what
  # the core would refuse once it sees the organisation's level: what a workspace held
  # before the organisation set its name.
  defp own!(workspace, target, variables) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Apiary.Variables.Variable,
      for {name, value} <- variables do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          target_id: target && target.id,
          name: name,
          value: value,
          locked: false,
          inserted_at: now,
          updated_at: now
        }
      end
    )
  end

  defp create!(scope, name, value, locked \\ false) do
    {:ok, variable} =
      OrganisationVariables.create(scope, %{name: name, value: value, locked: locked})

    variable
  end

  defp error(changeset, field) do
    {message, keys} = changeset.errors[field]

    Enum.reduce(keys, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  describe "reading" do
    test "the owners, the admins and the readers read them; a member does not", ctx do
      create!(ctx.owner, "LOG_LEVEL", "info")
      create!(ctx.owner, "api_base_url", "https://api.example")

      for reader <- [ctx.owner, ctx.admin] do
        assert {:ok, [%Variable{name: "api_base_url"}, %Variable{name: "LOG_LEVEL"}]} =
                 OrganisationVariables.list(reader)
      end

      instance_admin = instance_admin_fixture()
      reader = scope_in(instance_admin.user, ctx.organisation)
      assert {:ok, [_, _]} = OrganisationVariables.list(reader)
      assert {:ok, %{}} = OrganisationVariables.overrides(reader)

      assert {:error, :forbidden} = OrganisationVariables.list(ctx.member)
      assert {:error, :forbidden} = OrganisationVariables.overrides(ctx.member)
    end

    test "a variable of another organisation is not reachable", ctx do
      other = sign_up_fixture()
      theirs = create!(other.scope, "LOG_LEVEL", "debug")
      mine = create!(ctx.owner, "LOG_LEVEL", "info")

      assert {:ok, %Variable{value: "info"}} = OrganisationVariables.get(ctx.owner, mine.id)
      assert {:error, :not_found} = OrganisationVariables.get(ctx.owner, theirs.id)
      assert {:error, :not_found} = OrganisationVariables.get(ctx.owner, "not-an-id")

      for change <- [
            &OrganisationVariables.update(&1, theirs, %{value: "trace"}),
            &OrganisationVariables.lock(&1, theirs),
            &OrganisationVariables.unlock(&1, theirs.id),
            &OrganisationVariables.delete(&1, theirs)
          ] do
        assert {:error, :not_found} = change.(ctx.owner)
      end

      assert Repo.get!(Variable, theirs.id).value == "debug"
    end

    test "a suspended organisation is read, and changes nothing", ctx do
      create!(ctx.owner, "LOG_LEVEL", "info")
      admin = instance_admin_fixture()

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(admin.instance_scope, ctx.organisation.id)

      owner = Apiary.Access.reload(ctx.owner)
      assert {:ok, [_variable]} = OrganisationVariables.list(owner)

      assert {:error, :forbidden} =
               OrganisationVariables.create(owner, %{name: "REGION", value: "eu-west-1"})
    end
  end

  describe "who may change them" do
    test "an owner and an admin; a member and a reader do not", ctx do
      instance_admin = instance_admin_fixture()
      reader = scope_in(instance_admin.user, ctx.organisation)
      variable = create!(ctx.owner, "LOG_LEVEL", "info")

      for scope <- [ctx.member, reader] do
        assert {:error, :forbidden} =
                 OrganisationVariables.create(scope, %{name: "REGION", value: "eu-west-1"})

        assert {:error, :forbidden} =
                 OrganisationVariables.update(scope, variable, %{value: "debug"})

        assert {:error, :forbidden} = OrganisationVariables.lock(scope, variable)
        assert {:error, :forbidden} = OrganisationVariables.unlock(scope, variable)
        assert {:error, :forbidden} = OrganisationVariables.delete(scope, variable)
      end

      assert {:ok, _} = OrganisationVariables.update(ctx.admin, variable, %{value: "debug"})
      assert {:ok, _} = OrganisationVariables.lock(ctx.admin, variable)
      assert length(entries(ctx.organisation)) == 3
    end

    test "the level is read again under the locks", ctx do
      %{scope: second, membership: membership} = member_fixture(ctx.owner, :admin)
      {:ok, _} = Organisations.set_member_level(ctx.owner, membership.id, :member)

      assert {:error, :forbidden} =
               OrganisationVariables.create(second, %{name: "LOG_LEVEL", value: "info"})

      assert entries(ctx.organisation) == []
    end

    @tag with_features: [:observability, :security, :managed_organisations, :organisation_policy]
    test "without the feature nothing is found, and nothing reaches the workspaces", ctx do
      assert {:error, :not_found} = OrganisationVariables.list(ctx.owner)
      assert {:error, :not_found} = OrganisationVariables.overrides(ctx.owner)

      assert {:error, :not_found} =
               OrganisationVariables.create(ctx.owner, %{name: "LOG_LEVEL", value: "info"})

      Repo.insert!(%Variable{organisation_id: ctx.organisation.id, name: "LOG_LEVEL", value: "x"})

      assert OrganisationVariables.for_above(ctx.main) == []
      assert OrganisationVariables.for_above(ctx.organisation) == []
    end
  end

  describe "a name and a value" do
    test "are checked as the core checks a workspace's, with its sentences", ctx do
      for {attrs, field, message} <- [
            {%{name: "1ST", value: "x"}, :name,
             "must start with a letter or _ and hold only letters, digits and _, at most 128"},
            {%{name: "LOG-LEVEL", value: "x"}, :name,
             "must start with a letter or _ and hold only letters, digits and _, at most 128"},
            {%{name: "LOG_LEVEL", value: "one\ntwo"}, :value,
             "must be one line, with no NUL byte"},
            {%{name: "LOG_LEVEL", value: String.duplicate("x", 4097)}, :value,
             "must be at most 4096 bytes"},
            {%{name: "QORY_TOKEN", value: "x"}, :name,
             "names beginning QORY_ are reserved for Forager"},
            {%{name: "qory_anything", value: "x"}, :name,
             "names beginning QORY_ are reserved for Forager"}
          ] do
        assert {:error, changeset} = OrganisationVariables.create(ctx.owner, attrs)
        assert error(changeset, field) == message
      end

      assert entries(ctx.organisation) == []

      # An empty value is a value; a name is trimmed.
      assert %Variable{name: "EMPTY", value: ""} = create!(ctx.owner, "  EMPTY ", "")
    end

    test "is one per organisation, compared without case", ctx do
      variable = create!(ctx.owner, "LOG_LEVEL", "info")

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "log_level", value: "debug"})

      assert error(changeset, :name) == "is already set here, compared without case"

      # A variable may change the case of its own name.
      assert {:ok, %Variable{name: "Log_Level"}} =
               OrganisationVariables.update(ctx.owner, variable, %{name: "Log_Level"})
    end

    test "a different spelling a workspace or a repository set is refused, with its name",
         ctx do
      own!(ctx.main, nil, [{"log_level", "debug"}])
      site = target!(ctx.platform, "example/site")
      own!(ctx.platform, site, [{"Region", "us-east-1"}])

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "LOG_LEVEL", value: "info"})

      assert error(changeset, :name) == "is log_level in Main: use the same spelling"

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "REGION", value: "eu-west-1"})

      assert error(changeset, :name) == "is Region in Platform: use the same spelling"

      # The same spelling is the same name: the workspace's overrides it.
      assert %Variable{} = create!(ctx.owner, "log_level", "info")

      # A rename into another spelling is refused as a new name is.
      api = create!(ctx.owner, "API_BASE_URL", "https://api.example")

      assert {:error, changeset} =
               OrganisationVariables.update(ctx.owner, api, %{name: "region"})

      assert error(changeset, :name) == "is Region in Platform: use the same spelling"
      assert Repo.get!(Variable, api.id).name == "API_BASE_URL"
    end

    test "a clash a workspace made after the organisation set the name is said on any change",
         ctx do
      create!(ctx.owner, "LOG_LEVEL", "info")
      region = create!(ctx.owner, "REGION", "eu-west-1", true)
      zone = create!(ctx.owner, "ZONE", "a")
      own!(ctx.main, nil, [{"log_level", "debug"}])

      assert {:error, changeset} = OrganisationVariables.lock(ctx.owner, zone)

      assert error(changeset, :name) ==
               "cannot be locked while Main spells LOG_LEVEL as log_level: use one spelling"

      assert {:error, changeset} = OrganisationVariables.update(ctx.owner, zone, %{value: "b"})

      assert error(changeset, :name) ==
               "cannot be saved while Main spells LOG_LEVEL as log_level: use one spelling"

      # An unlock and a locked one's deletion are checked, and say what they were.
      assert {:error, changeset} = OrganisationVariables.unlock(ctx.owner, region)

      assert error(changeset, :name) ==
               "cannot be unlocked while Main spells LOG_LEVEL as log_level: use one spelling"

      assert {:error, changeset} = OrganisationVariables.delete(ctx.owner, region)

      assert error(changeset, :name) ==
               "cannot be deleted while Main spells LOG_LEVEL as log_level: use one spelling"

      # The deletion of an unlocked one adds no name, and is not held back by it.
      assert {:ok, _} = OrganisationVariables.delete(ctx.owner, zone)
    end
  end

  describe "the limits" do
    test "the organisation's own: at most 128 names", ctx do
      now = DateTime.utc_now()

      Repo.insert_all(
        Variable,
        for n <- 1..128 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: ctx.organisation.id,
            name: "NAME_#{n}",
            value: "x",
            locked: false,
            inserted_at: now,
            updated_at: now
          }
        end
      )

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "ONE_MORE", value: "x"})

      assert error(changeset, :name) == "would raise a target's variables above 128"
    end

    test "a workspace's: its own names and the organisation's together", ctx do
      own!(ctx.platform, nil, for(n <- 1..127, do: {"OWN_#{n}", "x"}))

      assert %Variable{} = create!(ctx.owner, "LOG_LEVEL", "info")

      # A name the workspace sets too adds nothing.
      assert %Variable{} = create!(ctx.owner, "OWN_1", "y")

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "REGION", value: "eu-west-1"})

      assert error(changeset, :name) == "would raise a target's variables in Platform above 128"
      assert {:error, :not_found} = find("REGION", ctx)
    end

    test "a repository's: 64 KiB of names and values, what a lock sets aside not counted",
         ctx do
      site = target!(ctx.main, "example/site")
      big = String.duplicate("x", 4000)
      own!(ctx.main, site, for(n <- 1..16, do: {"PART_#{n}", big}))

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "EXTRA", value: big})

      assert error(changeset, :value) ==
               "would raise a target's variables in Main above 64 KiB"

      # Locked, the organisation's short value is the one in force for PART_1, and the
      # repository's long one is set aside: within the limits, where unlocked it is not.
      part = create!(ctx.owner, "PART_1", "short", true)
      assert %Variable{} = create!(ctx.owner, "EXTRA", String.duplicate("x", 3000))

      assert {:error, changeset} = OrganisationVariables.unlock(ctx.owner, part)
      assert error(changeset, :value) == "would raise a target's variables in Main above 64 KiB"
      assert Repo.get!(Variable, part.id).locked

      # Deleted, it puts the repository's value back as an unlock does: refused alike.
      assert {:error, changeset} = OrganisationVariables.delete(ctx.owner, part)
      assert error(changeset, :value) == "would raise a target's variables in Main above 64 KiB"
      assert Repo.get!(Variable, part.id).locked
      assert length(entries(ctx.organisation)) == 2

      # An unlocked one puts nothing back; once it is gone, the locked one fits too.
      assert {:ok, _} = OrganisationVariables.delete(ctx.owner, find!("EXTRA", ctx))
      assert {:ok, _} = OrganisationVariables.delete(ctx.owner, part)
      assert {:ok, []} = OrganisationVariables.list(ctx.owner)
    end

    test "a workspace's locked variable is deleted no more past the limits than it is unlocked",
         ctx do
      %{owner: owner} = ctx
      site = target!(ctx.main, "example/site")
      big = String.duplicate("x", 4000)

      # 9 × (6 + 4000) + 6 × (7 + 4000) = 60096 bytes in the repository.
      for n <- 1..15 do
        {:ok, _} = Variables.create_variable(owner, site, %{name: "PART_#{n}", value: big})
      end

      # Locked, the workspace's 1 byte is the one in force for PART_1, and the
      # repository's 4000 are set aside: 56097 bytes, and room it fills to 61611.
      {:ok, part} = Variables.create_variable(owner, :workspace, %{name: "PART_1", value: "s"})
      {:ok, part} = Variables.lock_variable(owner, part)
      {:ok, _} = Variables.create_variable(owner, site, %{name: "PART_16", value: big})

      {:ok, _} =
        Variables.create_variable(owner, site, %{
          name: "PART_17",
          value: String.duplicate("x", 1500)
        })

      {:ok, resolution} = Variables.resolve(owner, site)
      assert Resolution.size(resolution).bytes == 61_611

      # The core's own refusal, a workspace's write: its words at the core's pin.
      # Unlocked or deleted, the repository's PART_1 would be back: 65610 bytes.
      assert {:error, changeset} = Variables.unlock_variable(owner, part)
      assert error(changeset, :value) == "would raise a target's variables above 64 KiB"

      assert {:error, changeset} = Variables.delete_variable(owner, part)
      assert error(changeset, :value) == "would raise a target's variables above 64 KiB"
      assert Repo.reload!(part).locked

      {:ok, resolution} = Variables.resolve(owner, site)
      assert Resolution.size(resolution).bytes == 61_611
    end

    test "a workspace marked for deletion that may be restored is checked", ctx do
      own!(ctx.platform, nil, for(n <- 1..127, do: {"OWN_#{n}", "x"}))
      own!(ctx.platform, nil, [{"log_level", "debug"}])
      {:ok, _} = Apiary.Deletion.delete_workspace(ctx.owner, ctx.platform.id, ctx.platform.slug)

      # Its spelling of a name, and its names with the organisation's, as if it were in use.
      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "LOG_LEVEL", value: "info"})

      assert error(changeset, :name) == "is log_level in Platform: use the same spelling"

      assert {:error, changeset} =
               OrganisationVariables.create(ctx.owner, %{name: "REGION", value: "eu-west-1"})

      assert error(changeset, :name) == "would raise a target's variables in Platform above 128"
      assert {:ok, []} = OrganisationVariables.list(ctx.owner)

      # Restored, it is within the limits and the spellings of the organisation's.
      assert {:ok, _} = Apiary.Deletion.restore_workspace(ctx.owner, ctx.platform.id)
    end

    test "a feature switched on again is not checked; the organisation's next change says so",
         ctx do
      %{owner: owner} = ctx
      log_level = create!(owner, "Log_Level", "info")
      create!(owner, "REGION", "eu-west-1")

      # Switched off on the instance, the organisation's variables reach no workspace, and a
      # workspace's writes are checked against none of them.
      Application.put_env(:apiary, :features, Features.all() -- [:organisation_variables])

      owner = Apiary.Access.reload(owner)
      own!(ctx.main, nil, for(n <- 1..126, do: {"OWN_#{n}", "x"}))

      # Longer than the organisation's "info", so deleting it makes Main no larger: the
      # core refuses a deletion that makes a holder larger and leaves it over a limit.
      assert {:ok, spelled} =
               Variables.create_variable(owner, :workspace, %{name: "LOG_LEVEL", value: "debug"})

      assert {:ok, last} =
               Variables.create_variable(owner, :workspace, %{name: "OWN_127", value: "x"})

      # Switched on again, nothing is checked: Main spells Log_Level otherwise, and with
      # REGION its names are 129.
      Application.put_env(:apiary, :features, Features.all())

      owner = Apiary.Access.reload(owner)
      assert [_, _] = OrganisationVariables.for_above(ctx.main)

      # The organisation's next change is refused, naming the workspace, until the
      # workspace changes or deletes its own variable.
      assert {:error, changeset} =
               OrganisationVariables.update(owner, log_level, %{value: "debug"})

      assert error(changeset, :name) == "is LOG_LEVEL in Main: use the same spelling"

      assert {:ok, _} = Variables.delete_variable(owner, spelled)

      assert {:error, changeset} =
               OrganisationVariables.update(owner, log_level, %{value: "debug"})

      assert error(changeset, :name) == "would raise a target's variables in Main above 128"

      assert {:ok, _} = Variables.delete_variable(owner, last)
      assert {:ok, _} = OrganisationVariables.update(owner, log_level, %{value: "debug"})
    end

    test "a workspace whose purge started is left out", ctx do
      own!(ctx.platform, nil, [{"log_level", "debug"}])
      {:ok, _} = Apiary.Deletion.delete_workspace(ctx.owner, ctx.platform.id, ctx.platform.slug)

      Repo.update_all(from(w in Organisations.Workspace, where: w.id == ^ctx.platform.id),
        set: [purge_started_at: DateTime.utc_now()]
      )

      assert %Variable{} = create!(ctx.owner, "LOG_LEVEL", "info")
    end
  end

  defp find!(name, ctx) do
    {:ok, variable} = find(name, ctx)
    variable
  end

  defp find(name, ctx) do
    case Repo.get_by(Variable, organisation_id: ctx.organisation.id, name: name) do
      nil -> {:error, :not_found}
      variable -> {:ok, variable}
    end
  end

  describe "a change" do
    test "is one entry of the variable's, by name and never by value", ctx do
      variable = create!(ctx.owner, "LOG_LEVEL", "secret-looking-value")
      {:ok, variable} = OrganisationVariables.update(ctx.owner, variable, %{value: "other-value"})
      {:ok, variable} = OrganisationVariables.update(ctx.owner, variable, %{name: "Log_Level"})
      {:ok, variable} = OrganisationVariables.lock(ctx.owner, variable)
      {:ok, variable} = OrganisationVariables.unlock(ctx.owner, variable)
      {:ok, _deleted} = OrganisationVariables.delete(ctx.owner, variable)

      entries = entries(ctx.organisation)

      assert Enum.map(entries, & &1.details["change"]) ==
               ~w(created updated updated locked unlocked deleted)

      for entry <- entries do
        assert {entry.subject_kind, entry.subject_id} == {"organisation_variable", variable.id}
        assert entry.workspace_id == nil
        assert entry.details["level"] == "organisation"
        assert entry.details["name"] in ["LOG_LEVEL", "Log_Level"]
        kept = Jason.encode!([entry.before, entry.after, entry.details])
        refute kept =~ "secret-looking-value"
        refute kept =~ "other-value"
      end

      [created, value, rename, locked, unlocked, deleted] = entries
      assert created.after == %{"name" => "LOG_LEVEL", "locked" => false}
      assert value.details["value_changed"] == true
      assert value.before == %{} and value.after == %{}
      assert rename.details["value_changed"] == false
      assert {rename.before, rename.after} == {%{"name" => "LOG_LEVEL"}, %{"name" => "Log_Level"}}
      assert {locked.before, locked.after} == {%{"locked" => false}, %{"locked" => true}}
      assert unlocked.after == %{"locked" => false}
      assert deleted.before == %{"name" => "Log_Level", "locked" => false}

      assert {:error, :not_found} = OrganisationVariables.get(ctx.owner, variable.id)
    end

    test "that changes nothing leaves no entry", ctx do
      variable = create!(ctx.owner, "LOG_LEVEL", "info")

      assert {:ok, ^variable} =
               OrganisationVariables.update(ctx.owner, variable, %{value: "info"})

      assert {:ok, %Variable{locked: false}} = OrganisationVariables.unlock(ctx.owner, variable)
      assert length(entries(ctx.organisation)) == 1
    end

    test "says who changed it, and tells the organisation's pages", ctx do
      OrganisationVariables.subscribe(ctx.owner)
      variable = create!(ctx.owner, "LOG_LEVEL", "info")
      organisation_id = ctx.organisation.id

      assert_receive {:organisation_variables_changed,
                      %{organisation_id: ^organisation_id, change: "created", name: "LOG_LEVEL"}}

      {:ok, changed} = OrganisationVariables.update(ctx.admin, variable, %{value: "debug"})
      assert changed.created_by_id == ctx.owner.user.id
      assert changed.updated_by_id == ctx.admin.user.id

      assert_receive {:organisation_variables_changed, %{change: "updated"}}

      {:ok, _} = OrganisationVariables.update(ctx.admin, changed, %{value: "debug"})
      refute_receive {:organisation_variables_changed, _}
    end
  end

  describe "the workspaces" do
    test "are counted by the names they and their repositories set themselves", ctx do
      create!(ctx.owner, "LOG_LEVEL", "info")
      create!(ctx.owner, "REGION", "eu-west-1", true)
      create!(ctx.owner, "API_BASE_URL", "https://api.example")

      site = target!(ctx.main, "example/site")
      docs = target!(ctx.platform, "example/docs")
      own!(ctx.main, nil, [{"LOG_LEVEL", "debug"}])
      own!(ctx.main, site, [{"LOG_LEVEL", "trace"}, {"REGION", "us-east-1"}])
      own!(ctx.platform, nil, [{"LOG_LEVEL", "warn"}, {"OWN_ONLY", "x"}])
      own!(ctx.platform, docs, [{"REGION", "ap-south-1"}])

      # Main locks REGION itself, and so holds its site's REGION aside whatever the
      # organisation's lock does.
      own!(ctx.main, nil, [{"REGION", "eu-central-1"}])

      {1, _} =
        Repo.update_all(
          from(v in Apiary.Variables.Variable,
            where: v.workspace_id == ^ctx.main.id and is_nil(v.target_id) and v.name == "REGION"
          ),
          set: [locked: true]
        )

      # Another organisation's, and a workspace marked for deletion, are not counted.
      other = sign_up_fixture()
      own!(other.workspace, nil, [{"LOG_LEVEL", "debug"}])
      gone = workspace_fixture(ctx.organisation, "Gone")
      own!(gone, nil, [{"REGION", "x"}])
      {:ok, _} = Apiary.Deletion.delete_workspace(ctx.owner, gone.id, gone.slug)

      assert {:ok, overrides} = OrganisationVariables.overrides(ctx.admin)

      assert overrides == %{
               "log_level" => %{workspaces: 2, repositories: 1, workspace_locked: 0},
               "region" => %{workspaces: 1, repositories: 2, workspace_locked: 1},
               "api_base_url" => %{workspaces: 0, repositories: 0, workspace_locked: 0}
             }
    end
  end

  describe "the level above" do
    test "is the organisation's variables as the core's structs, by name", ctx do
      create!(ctx.owner, "region", "eu-west-1", true)
      create!(ctx.owner, "LOG_LEVEL", "info")

      assert [
               %Apiary.Variables.Variable{name: "LOG_LEVEL", value: "info", locked: false},
               %Apiary.Variables.Variable{
                 name: "region",
                 value: "eu-west-1",
                 locked: true,
                 workspace_id: nil,
                 target_id: nil
               } = region
             ] = OrganisationVariables.for_above(ctx.main)

      assert region.organisation_id == ctx.organisation.id

      assert OrganisationVariables.for_above(ctx.organisation) ==
               OrganisationVariables.for_above(ctx.platform)

      # The edition's level carries them, so the core resolves them in every workspace.
      assert {:ok, resolution} = Variables.resolve(ctx.owner, :workspace)

      assert Variables.Resolution.values(resolution) == %{
               "LOG_LEVEL" => "info",
               "region" => "eu-west-1"
             }

      assert %{set_by: :above, locked_by: :above} =
               Variables.Resolution.entry(resolution, "REGION")
    end
  end

  describe "the organisation's deletion" do
    test "takes its variables with it", ctx do
      create!(ctx.owner, "LOG_LEVEL", "info")
      assert {:ok, :purged} = Apiary.Deletion.purge_now(ctx.organisation)

      refute Repo.exists?(from v in Variable, where: v.organisation_id == ^ctx.organisation.id)
    end
  end
end

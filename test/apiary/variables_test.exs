defmodule Apiary.VariablesTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Variables
  alias Apiary.Audit.Entry
  alias Apiary.Runs.Target
  alias Apiary.Variables.{Resolution, Variable}

  setup do
    owner = sign_up_fixture()
    %{owner: owner, scope: owner.scope, site: target!(owner.scope, "example/site")}
  end

  defp target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp set!(scope, holder, name, value, attrs \\ %{}) do
    {:ok, variable} =
      Variables.create_variable(scope, holder, Map.merge(%{name: name, value: value}, attrs))

    variable
  end

  defp values(scope, holder), do: scope |> Variables.resolve(holder) |> Resolution.values()

  defp error(changeset, field) do
    {message, keys} = changeset.errors[field]

    Enum.reduce(keys, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  describe "levels" do
    test "a repository takes the workspace's variables and overrides them with its own",
         %{scope: scope, site: site} do
      set!(scope, :workspace, "NODE_ENV", "production")
      set!(scope, :workspace, "REGION", "eu-west-1")
      set!(scope, site, "NODE_ENV", "test")
      set!(scope, site, "SITE_ONLY", "yes")

      assert values(scope, :workspace) == %{"NODE_ENV" => "production", "REGION" => "eu-west-1"}

      assert values(scope, site) == %{
               "NODE_ENV" => "test",
               "REGION" => "eu-west-1",
               "SITE_ONLY" => "yes"
             }

      other = target!(scope, "example/other")
      assert values(scope, other) == values(scope, :workspace)
    end

    test "the resolution says which level set each name and which locked it",
         %{scope: scope, site: site} do
      set!(scope, :workspace, "NODE_ENV", "production")
      set!(scope, :workspace, "LOG_LEVEL", "info", %{locked: true})
      set!(scope, site, "NODE_ENV", "test")

      resolution = Variables.resolve(scope, site)

      assert Resolution.entry(resolution, "node_env") == %{
               name: "NODE_ENV",
               value: "test",
               set_by: :target,
               locked_by: nil,
               ignored: []
             }

      assert %{set_by: :workspace, locked_by: :workspace} =
               Resolution.entry(resolution, "LOG_LEVEL")

      assert [%Variable{name: "NODE_ENV"}] = Variables.list_variables(scope, site)

      assert ["LOG_LEVEL", "NODE_ENV"] =
               Enum.map(Variables.list_variables(scope, :workspace), & &1.name)
    end

    test "a value may be empty, and is one line of at most 4096 bytes", %{scope: scope} do
      assert %{value: ""} = set!(scope, :workspace, "EMPTY", "")
      assert set!(scope, :workspace, "LONGEST", String.duplicate("a", 4096))

      for {value, message} <- [
            {String.duplicate("a", 4097), "must be at most 4096 bytes"},
            {"two\nlines", "must be one line, with no NUL byte"},
            {"carriage\rreturn", "must be one line, with no NUL byte"},
            {"nul" <> <<0>>, "must be one line, with no NUL byte"},
            {<<0xFF>>, "must be UTF-8 text"},
            {nil, "can't be blank"}
          ] do
        assert {:error, changeset} =
                 Variables.create_variable(scope, :workspace, %{name: "BAD", value: value})

        assert error(changeset, :value) == message
      end
    end

    test "a name keeps a variable's rule", %{scope: scope} do
      for name <- ["a", "_X", "Mixed_9", String.duplicate("A", 128)] do
        assert {:ok, _} = Variables.create_variable(scope, :workspace, %{name: name, value: "v"})
      end

      for name <- ["", "9A", "A-B", "A B", String.duplicate("A", 129)] do
        assert {:error, changeset} =
                 Variables.create_variable(scope, :workspace, %{name: name, value: "v"})

        assert changeset.errors[:name], "#{inspect(name)} was taken"
      end
    end
  end

  describe "names compared without case" do
    test "a level holds a name once", %{scope: scope, site: site} do
      set!(scope, :workspace, "NODE_ENV", "a")
      set!(scope, site, "NODE_ENV", "b")

      assert {:error, changeset} =
               Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "c"})

      assert error(changeset, :name) == "is already set here, compared without case"

      assert {:error, changeset} =
               Variables.create_variable(scope, site, %{name: "NODE_ENV", value: "c"})

      assert error(changeset, :name) == "is already set here, compared without case"
    end

    test "another spelling of a name in the same chain is refused at the level being saved",
         %{scope: scope, site: site} do
      set!(scope, :workspace, "NODE_ENV", "a")

      assert {:error, changeset} =
               Variables.create_variable(scope, site, %{name: "node_env", value: "b"})

      assert error(changeset, :name) ==
               "is NODE_ENV elsewhere in this workspace: use the same spelling"

      set!(scope, site, "Region", "eu")

      assert {:error, changeset} =
               Variables.create_variable(scope, :workspace, %{name: "REGION", value: "us"})

      assert error(changeset, :name) ==
               "is Region elsewhere in this workspace: use the same spelling"

      # Two repositories are no chain: each may spell its own.
      other = target!(scope, "example/other")
      assert {:ok, _} = Variables.create_variable(scope, other, %{name: "REGION", value: "us"})
    end

    test "a variable may change the case of its own name", %{scope: scope} do
      variable = set!(scope, :workspace, "node_env", "a")

      assert {:ok, %{name: "NODE_ENV"}} =
               Variables.update_variable(scope, variable, %{name: "NODE_ENV"})
    end
  end

  describe "QORY_ names" do
    test "are refused at every level, whatever their case", %{scope: scope, site: site} do
      for holder <- [:workspace, site],
          name <- ["QORY_TOKEN", "qory_anything", "Qory_", "QORY_"] do
        assert {:error, changeset} =
                 Variables.create_variable(scope, holder, %{name: name, value: "v"})

        assert error(changeset, :name) == "names beginning QORY_ are the runner's own"
      end

      variable = set!(scope, :workspace, "QORYX", "fine")

      assert {:error, changeset} = Variables.update_variable(scope, variable, %{name: "QORY_X"})
      assert error(changeset, :name) == "names beginning QORY_ are the runner's own"
    end
  end

  describe "locks" do
    test "a repository cannot set a name the workspace locks", %{scope: scope, site: site} do
      set!(scope, :workspace, "LOG_LEVEL", "info", %{locked: true})

      for name <- ["LOG_LEVEL", "log_level"] do
        assert {:error, changeset} =
                 Variables.create_variable(scope, site, %{name: name, value: "debug"})

        assert error(changeset, :name) == "is locked above, so it cannot be set here"
      end
    end

    test "a lock set after a repository's own value sets that value aside",
         %{scope: scope, site: site} do
      workspace_variable = set!(scope, :workspace, "LOG_LEVEL", "info")
      own = set!(scope, site, "LOG_LEVEL", "debug")
      assert values(scope, site)["LOG_LEVEL"] == "debug"

      assert {:ok, %{locked: true}} = Variables.lock_variable(scope, workspace_variable)
      assert values(scope, site)["LOG_LEVEL"] == "info"

      assert %{set_by: :workspace, locked_by: :workspace, ignored: [:target]} =
               Resolution.entry(Variables.resolve(scope, site), "LOG_LEVEL")

      # The repository's own value may be removed, not changed, while the lock holds.
      assert {:error, changeset} = Variables.update_variable(scope, own, %{value: "trace"})
      assert error(changeset, :name) == "is locked above, so it cannot be set here"

      assert {:ok, %{locked: false}} = Variables.unlock_variable(scope, workspace_variable)
      assert values(scope, site)["LOG_LEVEL"] == "debug"
      assert {:ok, _} = Variables.delete_variable(scope, own)
      assert values(scope, site)["LOG_LEVEL"] == "info"
    end

    test "only a workspace's variable is locked", %{scope: scope, site: site} do
      own = set!(scope, site, "SITE", "x", %{locked: true})
      assert own.locked == false

      assert {:error, changeset} = Variables.lock_variable(scope, own)
      assert changeset.errors[:locked]

      assert_raise Postgrex.Error, ~r/variables_locked_is_the_workspaces_check/, fn ->
        Repo.query!("UPDATE variables SET locked = true WHERE id = $1", [Ecto.UUID.dump!(own.id)])
      end
    end
  end

  describe "limits" do
    test "a holder has at most 128 names", %{scope: scope, site: site} do
      for i <- 1..120, do: set!(scope, :workspace, "W#{i}", "")
      for i <- 1..8, do: set!(scope, site, "T#{i}", "")

      # The repository is full: the workspace cannot add a name it would take.
      assert {:error, changeset} =
               Variables.create_variable(scope, :workspace, %{name: "W121", value: ""})

      assert error(changeset, :name) == "would give a run more than 128 variables"

      assert {:error, _} = Variables.create_variable(scope, site, %{name: "T9", value: ""})

      # Overriding a name adds none.
      assert {:ok, _} = Variables.create_variable(scope, site, %{name: "W1", value: "own"})
      assert Resolution.size(Variables.resolve(scope, site)).names == 128
      assert Repo.aggregate(from(v in Variable, where: v.name == "W121"), :count) == 0
    end

    test "a holder has at most 64 KiB of names and values", %{scope: scope, site: site} do
      # 15 variables of a 4-byte name and 4096 bytes: 61500 bytes.
      for i <- 10..24, do: set!(scope, :workspace, "V_#{i}", String.duplicate("v", 4096))

      # 61500 + 4 + 4032 = 65536: exactly the limit.
      assert {:ok, last} =
               Variables.create_variable(scope, site, %{
                 name: "LAST",
                 value: String.duplicate("v", 4032)
               })

      assert Resolution.size(Variables.resolve(scope, site)).bytes == 65_536

      assert {:error, changeset} =
               Variables.update_variable(scope, last, %{value: String.duplicate("v", 4033)})

      assert error(changeset, :value) == "would give a run more than 64 KiB of variables"

      assert {:error, _} =
               Variables.create_variable(scope, :workspace, %{name: "MORE", value: "x"})
    end
  end

  describe "who, where and the trail" do
    test "a member reads the variables and changes none", %{scope: scope, site: site} do
      variable = set!(scope, :workspace, "NODE_ENV", "production")
      %{scope: member} = member_fixture(scope)

      assert [%Variable{}] = Variables.list_variables(member, :workspace)
      assert values(member, site) == %{"NODE_ENV" => "production"}

      assert Variables.create_variable(member, :workspace, %{name: "A", value: "b"}) ==
               {:error, :forbidden}

      assert Variables.create_variable(member, site, %{name: "A", value: "b"}) ==
               {:error, :forbidden}

      assert Variables.update_variable(member, variable, %{value: "x"}) == {:error, :forbidden}
      assert Variables.lock_variable(member, variable) == {:error, :forbidden}
      assert Variables.delete_variable(member, variable) == {:error, :forbidden}
    end

    test "an admin changes them", %{scope: scope} do
      %{scope: admin} = member_fixture(scope, :admin)

      assert {:ok, variable} =
               Variables.create_variable(admin, :workspace, %{name: "A", value: "b"})

      assert {:ok, _} = Variables.lock_variable(admin, variable)
    end

    test "another organisation's variables and repositories are out of reach",
         %{scope: scope, site: site} do
      variable = set!(scope, :workspace, "NODE_ENV", "production")
      other = sign_up_fixture().scope

      assert Variables.list_variables(other, :workspace) == []
      assert Variables.get_variable(other, variable.id) == {:error, :not_found}
      assert Variables.update_variable(other, variable, %{value: "x"}) == {:error, :not_found}
      assert Variables.delete_variable(other, variable) == {:error, :not_found}

      assert Variables.create_variable(other, site, %{name: "A", value: "b"}) ==
               {:error, :not_found}

      assert {:ok, ^variable} = Variables.get_variable(scope, variable.id)
    end

    test "every change leaves one entry by name, never by value", %{scope: scope, site: site} do
      variable = set!(scope, :workspace, "NODE_ENV", "first-value")
      {:ok, variable} = Variables.update_variable(scope, variable, %{value: "second-value"})
      {:ok, variable} = Variables.update_variable(scope, variable, %{name: "APP_ENV"})
      {:ok, variable} = Variables.lock_variable(scope, variable)
      {:ok, variable} = Variables.unlock_variable(scope, variable)
      {:ok, _} = Variables.delete_variable(scope, variable)
      own = set!(scope, site, "SITE", "site-value")

      entries =
        Repo.all(
          from e in Entry,
            where: e.subject_kind == "variable",
            order_by: [asc: e.inserted_at, asc: e.id]
        )

      assert Enum.all?(entries, &(&1.action == "variable.edit"))

      assert Enum.map(entries, &{&1.details["change"], &1.details["name"]}) == [
               {"created", "NODE_ENV"},
               {"updated", "NODE_ENV"},
               {"updated", "APP_ENV"},
               {"locked", "APP_ENV"},
               {"unlocked", "APP_ENV"},
               {"deleted", "APP_ENV"},
               {"created", "SITE"}
             ]

      [_created, value_changed, renamed | _] = entries
      assert value_changed.details["value_changed"] == true
      assert value_changed.before == %{}
      assert {renamed.before, renamed.after} == {%{"name" => "NODE_ENV"}, %{"name" => "APP_ENV"}}
      assert List.last(entries).details["target_id"] == own.target_id
      assert List.last(entries).details["level"] == "target"

      kept = Jason.encode!(Enum.map(entries, &[&1.before, &1.after, &1.details]))
      for value <- ["first-value", "second-value", "site-value"], do: refute(kept =~ value)

      # A change that changes nothing leaves none.
      assert {:ok, _} = Variables.update_variable(scope, own, %{value: "site-value"})
      assert Repo.aggregate(from(e in Entry, where: e.subject_kind == "variable"), :count) == 7
    end

    test "a repository's variables go with it", %{scope: scope, site: site} do
      own = set!(scope, site, "SITE", "x")
      Repo.delete!(site)
      assert Variables.get_variable(scope, own.id) == {:error, :not_found}
    end
  end
end

defmodule Apiary.InstanceConfigTest do
  @moduledoc """
  The instance's settings an instance admin saves in Instance settings › Configuration
  (`Apiary.InstanceConfig`): each value, the environment's before the saved one before
  the default; the address never kept longer than its entry, and the trail never longer
  than the edition's ceiling; the save, its bounds and their words, who may save, and the
  instance's trail; each node's copy (`Apiary.InstanceConfig.Cache`); and the database's
  checks.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the environment's values and the cache's copy are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Deletion, Instance, InstanceConfig, Organisations, ProductName}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.MachineLogs
  alias Apiary.InstanceConfig.{Cache, Row}

  @days "must be between %{min} and %{max} days, or empty for the default"
  @invitations "must be a whole number from 1 to 1,000,000, or empty for the default"

  @env_keys ~w(audit_retention_days audit_address_retention_days deletion_grace_days
               invitations_per_day machine_log_retention_days)a

  # Puts the application's setting `key` for the test, and back after it.
  defp put_env(key, value) do
    before = Application.fetch_env(:apiary, key)
    Application.put_env(:apiary, key, value)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, key, value)
        :error -> Application.delete_env(:apiary, key)
      end
    end)
  end

  # `scope` as a sign-in `minutes` ago leaves it (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in(scope, minutes \\ 0),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), -minutes, :minute))

  # Writes `values` to the instance's row as they are, past the save's checks.
  defp saved!(values) do
    Repo.insert_all(
      Row,
      [Map.merge(%{id: true, updated_at: DateTime.utc_now()}, values)],
      on_conflict: {:replace, Map.keys(values)},
      conflict_target: :id
    )
  end

  defp days(min, max),
    do: @days |> String.replace("%{min}", to_string(min)) |> String.replace("%{max}", max)

  # The trail's entries of `instance.configure` in the instance's organisation.
  defp entries do
    Repo.all(
      from e in Entry,
        where: e.action == "instance.configure",
        where: e.organisation_id == ^Apiary.Edition.instance_organisation_id(),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp errors(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  setup do
    # The variables, whatever the shell running the suite set: none.
    for key <- @env_keys, do: put_env(key, nil)

    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    %{scope: signed_in(scope)}
  end

  describe "value/1 and source/1" do
    test "with nothing set, the default: 90, 90, 30 days, 20 and 30 days" do
      assert InstanceConfig.values(InstanceConfig.load()) == %{
               audit_retention_days: 90,
               audit_address_retention_days: 90,
               deletion_grace_days: 30,
               invitations_per_day: 20,
               machine_log_retention_days: 30
             }

      for key <- InstanceConfig.keys() do
        assert InstanceConfig.source(key) == :default
        assert InstanceConfig.env(key) == nil
      end

      assert Audit.retention_days() == 90
      assert Audit.address_retention_days() == 90
      assert Deletion.grace_days() == 30
      assert Instance.invitations_per_day() == 20
      assert MachineLogs.retention_days() == 30
    end

    test "the saved value, where the environment sets none" do
      saved!(%{
        audit_retention_days: 60,
        audit_address_retention_days: 14,
        deletion_grace_days: 7,
        invitations_per_day: 50,
        machine_log_retention_days: 21
      })

      assert Audit.retention_days() == 60
      assert Audit.address_retention_days() == 14
      assert Deletion.grace_days() == 7
      assert Instance.invitations_per_day() == 50
      assert MachineLogs.retention_days() == 21
      for key <- InstanceConfig.keys(), do: assert(InstanceConfig.source(key) == :saved)
    end

    test "the environment's value, set and not blank, wins over the saved one" do
      saved!(%{
        audit_retention_days: 60,
        audit_address_retention_days: 14,
        deletion_grace_days: 7,
        invitations_per_day: 50,
        machine_log_retention_days: 21
      })

      put_env(:audit_retention_days, 45)
      put_env(:audit_address_retention_days, 10)
      put_env(:deletion_grace_days, 3)
      put_env(:invitations_per_day, 5)
      put_env(:machine_log_retention_days, 14)

      assert Audit.retention_days() == 45
      assert Audit.address_retention_days() == 10
      assert Deletion.grace_days() == 3
      assert Instance.invitations_per_day() == 5
      assert MachineLogs.retention_days() == 14
      for key <- InstanceConfig.keys(), do: assert(InstanceConfig.source(key) == :env)
    end

    test "a blank variable is kept as none, so the saved value applies; a set one is kept" do
      settings =
        ~w(audit_retention_setting audit_address_retention_setting deletion_grace_setting
           invitations_per_day_setting machine_log_retention_setting)a

      for key <- settings, do: put_env(key, " ")

      saved!(%{
        audit_retention_days: 60,
        audit_address_retention_days: 14,
        deletion_grace_days: 7,
        invitations_per_day: 50,
        machine_log_retention_days: 21
      })

      # Each boot answers what the variable gives, the default for a blank one.
      assert Audit.boot!() == 90
      assert Deletion.boot!() == 30
      assert Instance.boot!() == 20
      assert MachineLogs.boot!() == 30

      for key <- @env_keys, do: assert(Application.fetch_env!(:apiary, key) == nil)

      assert Audit.retention_days() == 60
      assert Audit.address_retention_days() == 14
      assert Deletion.grace_days() == 7
      assert Instance.invitations_per_day() == 50

      put_env(:audit_retention_setting, "45")
      put_env(:audit_address_retention_setting, " 10 ")
      put_env(:deletion_grace_setting, "3")
      put_env(:invitations_per_day_setting, "5")
      put_env(:machine_log_retention_setting, "14")

      assert Audit.boot!() == 45
      assert Deletion.boot!() == 3
      assert Instance.boot!() == 5
      assert MachineLogs.boot!() == 14

      assert Map.new(@env_keys, &{&1, Application.fetch_env!(:apiary, &1)}) == %{
               audit_retention_days: 45,
               audit_address_retention_days: 10,
               deletion_grace_days: 3,
               invitations_per_day: 5,
               machine_log_retention_days: 14
             }

      assert Audit.retention_days() == 45
      assert Instance.invitations_per_day() == 5
    end
  end

  describe "the address, never kept longer than its entry" do
    test "follows a shorter trail, whatever sets either" do
      put_env(:audit_address_retention_days, 80)
      saved!(%{audit_retention_days: 30})

      assert Audit.retention_days() == 30
      assert Audit.address_retention_days() == 30
      assert InstanceConfig.source(:audit_address_retention_days) == :env

      put_env(:audit_address_retention_days, nil)
      saved!(%{audit_retention_days: 60, audit_address_retention_days: 80})
      assert Audit.address_retention_days() == 60
    end

    test "its default is the trail's period, where that is shorter than 90 days" do
      saved!(%{audit_retention_days: 60})
      assert Audit.address_retention_days() == 60
      assert InstanceConfig.source(:audit_address_retention_days) == :default

      put_env(:audit_retention_days, 45)
      assert Audit.address_retention_days() == 45
    end
  end

  describe "the edition's ceiling" do
    test "a saved trail's period above it reads as the ceiling, and a save above it is refused",
         %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ShortRetention)
      assert Apiary.Edition.audit_retention_max_days() == 60

      saved!(%{audit_retention_days: 90, audit_address_retention_days: 90})
      assert Audit.retention_days() == 60
      assert Audit.address_retention_days() == 60

      saved!(%{audit_retention_days: nil, audit_address_retention_days: nil})
      assert Audit.retention_days() == 60
      assert Audit.address_retention_days() == 60

      assert errors(InstanceConfig.save(scope, :retention, %{"audit_retention_days" => "61"})) ==
               %{audit_retention_days: [days(30, "60")]}

      assert {:ok, %{audit_retention_days: 60}} =
               InstanceConfig.save(scope, :retention, %{"audit_retention_days" => "60"})
    end
  end

  describe "save/3" do
    test "makes the row where there is none, and writes only the part's settings",
         %{scope: scope} do
      Repo.delete_all("instance_settings")

      assert {:ok, values} =
               InstanceConfig.save(scope, :retention, %{
                 "audit_retention_days" => "60",
                 "audit_address_retention_days" => "14",
                 "deletion_grace_days" => "5",
                 "invitations_per_day" => "9"
               })

      assert values == %{
               audit_retention_days: 60,
               audit_address_retention_days: 14,
               deletion_grace_days: 30,
               invitations_per_day: 20,
               machine_log_retention_days: 30
             }

      assert InstanceConfig.load() == %{
               audit_retention_days: 60,
               audit_address_retention_days: 14,
               deletion_grace_days: nil,
               invitations_per_day: nil,
               machine_log_retention_days: nil
             }

      assert {:ok, _values} =
               InstanceConfig.save(scope, :deletion, %{
                 "deletion_grace_days" => "7",
                 "audit_retention_days" => "30"
               })

      assert {:ok, _values} =
               InstanceConfig.save(scope, :invitations, %{"invitations_per_day" => "50"})

      assert {:ok, _values} =
               InstanceConfig.save(scope, :machine_logs, %{"machine_log_retention_days" => "21"})

      assert InstanceConfig.load() == %{
               audit_retention_days: 60,
               audit_address_retention_days: 14,
               deletion_grace_days: 7,
               invitations_per_day: 50,
               machine_log_retention_days: 21
             }
    end

    test "leaves a setting the environment sets as it is", %{scope: scope} do
      put_env(:audit_address_retention_days, 20)

      assert {:ok, %{audit_retention_days: 60, audit_address_retention_days: 20}} =
               InstanceConfig.save(scope, :retention, %{
                 "audit_retention_days" => "60",
                 "audit_address_retention_days" => "10"
               })

      assert %{audit_retention_days: 60, audit_address_retention_days: nil} =
               InstanceConfig.load()

      put_env(:invitations_per_day, 5)

      assert {:ok, %{invitations_per_day: 5}} =
               InstanceConfig.save(scope, :invitations, %{"invitations_per_day" => "0"})

      assert InstanceConfig.load().invitations_per_day == nil
    end

    test "trims each value; an empty one is none saved, and the default applies",
         %{scope: scope} do
      assert {:ok, %{deletion_grace_days: 14}} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => " 14 "})

      assert InstanceConfig.load().deletion_grace_days == 14

      assert {:ok, %{deletion_grace_days: 30}} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => "  "})

      assert InstanceConfig.load().deletion_grace_days == nil
      assert InstanceConfig.source(:deletion_grace_days) == :default
    end

    test "never writes who set the product's name", %{scope: scope} do
      assert {:ok, "Acme Agents"} = ProductName.rename(scope, %{"product_name" => "Acme Agents"})

      %{user: other} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(other)
      other = signed_in(Scope.for_user(other))

      assert {:ok, _values} =
               InstanceConfig.save(other, :invitations, %{"invitations_per_day" => "50"})

      assert Repo.one!(from s in "instance_settings", select: {s.product_name, s.updated_by_id}) ==
               {"Acme Agents", Ecto.UUID.dump!(scope.user.id)}
    end
  end

  describe "save/3, the bounds" do
    test "the trail's period: 30 to 90 days, a whole number", %{scope: scope} do
      save = &InstanceConfig.save(scope, :retention, %{"audit_retention_days" => &1})

      for value <- ["29", "91", "abc", "60.5", "-30"] do
        assert errors(save.(value)) == %{audit_retention_days: [days(30, "90")]}, value
      end

      assert InstanceConfig.load().audit_retention_days == nil

      for {value, days} <- [{"30", 30}, {"90", 90}, {" 60 ", 60}] do
        assert {:ok, %{audit_retention_days: ^days}} = save.(value)
      end
    end

    test "the address's period: from 1 day, not longer than the trail's", %{scope: scope} do
      save = &InstanceConfig.save(scope, :retention, &1)

      for value <- ["0", "-1", "abc"] do
        assert errors(save.(%{"audit_address_retention_days" => value})) ==
                 %{audit_address_retention_days: [days(1, "90")]},
               value
      end

      assert {:ok, %{audit_address_retention_days: 1}} =
               save.(%{"audit_address_retention_days" => "1"})

      # Longer than the trail's period typed beside it.
      assert errors(
               save.(%{
                 "audit_retention_days" => "60",
                 "audit_address_retention_days" => "61"
               })
             ) == %{
               audit_address_retention_days: [
                 "cannot be longer than the audit log entries are kept: 60 days"
               ]
             }

      # And with the range's bound named as the trail's.
      assert errors(
               save.(%{"audit_retention_days" => "60", "audit_address_retention_days" => "0"})
             ) == %{audit_address_retention_days: [days(1, "60")]}

      # Longer than the trail's period the environment sets.
      put_env(:audit_retention_days, 45)

      assert errors(save.(%{"audit_address_retention_days" => "50"})) == %{
               audit_address_retention_days: [
                 "cannot be longer than the audit log entries are kept: 45 days"
               ]
             }

      assert {:ok, %{audit_address_retention_days: 45}} =
               save.(%{"audit_address_retention_days" => "45"})
    end

    test "the trail's period is not shorter than the address's the environment sets",
         %{scope: scope} do
      put_env(:audit_address_retention_days, 80)
      save = &InstanceConfig.save(scope, :retention, %{"audit_retention_days" => &1})

      assert errors(save.("60")) == %{
               audit_retention_days: [
                 "cannot be shorter than the IP addresses are kept: 80 days"
               ]
             }

      assert {:ok, %{audit_retention_days: 80, audit_address_retention_days: 80}} =
               save.("80")
    end

    test "the grace period: 1 to 90 days, a whole number", %{scope: scope} do
      save = &InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => &1})

      for value <- ["0", "91", "a month"] do
        assert errors(save.(value)) == %{deletion_grace_days: [days(1, "90")]}, value
      end

      for {value, days} <- [{"1", 1}, {"90", 90}] do
        assert {:ok, %{deletion_grace_days: ^days}} = save.(value)
      end
    end

    test "the invitations a day: 1 to 1,000,000, a whole number", %{scope: scope} do
      save = &InstanceConfig.save(scope, :invitations, %{"invitations_per_day" => &1})

      for value <- ["0", "1000001", "twenty", "99999999999999"] do
        assert errors(save.(value)) == %{invitations_per_day: [@invitations]}, value
      end

      assert InstanceConfig.invitations_max() == 1_000_000

      for {value, limit} <- [{"1", 1}, {"1000000", 1_000_000}] do
        assert {:ok, %{invitations_per_day: ^limit}} = save.(value)
      end
    end
  end

  describe "save/3, who may" do
    test "an instance admin who signed in recently; one who did not signs in again first",
         %{scope: scope} do
      assert InstanceConfig.authorize_save(scope) == :ok

      for stale <- [signed_in(scope, 21), put_in(scope.user.authenticated_at, nil)] do
        assert InstanceConfig.authorize_save(stale) == {:error, :sudo}

        assert InstanceConfig.save(stale, :invitations, %{"invitations_per_day" => "50"}) ==
                 {:error, :sudo}
      end

      assert InstanceConfig.load().invitations_per_day == nil
      assert entries() == []
    end

    test "nobody else", %{scope: scope} do
      member = member_fixture(scope)
      %{scope: other} = sign_up_fixture()

      for refused <- [signed_in(member.scope), signed_in(other), nil] do
        assert InstanceConfig.authorize_save(refused) == {:error, :forbidden}

        assert InstanceConfig.save(refused, :invitations, %{"invitations_per_day" => "50"}) ==
                 {:error, :forbidden}
      end

      assert InstanceConfig.load().invitations_per_day == nil
      assert entries() == []
    end
  end

  describe "save/3, the instance's trail" do
    test "is an instance.configure entry, by the admin, with the values before and after",
         %{scope: scope} do
      assert {:ok, _values} =
               InstanceConfig.save(scope, :invitations, %{"invitations_per_day" => "50"})

      assert [entry] = entries()
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      assert {entry.before, entry.after} ==
               {%{"invitations_per_day" => 20}, %{"invitations_per_day" => 50}}
    end

    test "a shorter trail that shortens the address's period says both", %{scope: scope} do
      assert {:ok, _values} =
               InstanceConfig.save(scope, :retention, %{"audit_retention_days" => "60"})

      assert [entry] = entries()

      assert {entry.before, entry.after} ==
               {%{"audit_retention_days" => 90, "audit_address_retention_days" => 90},
                %{"audit_retention_days" => 60, "audit_address_retention_days" => 60}}
    end

    test "none for a save that changes no value, a refused one, or one in error",
         %{scope: scope} do
      # The default's number typed in changes the row and no value.
      assert {:ok, _values} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => "30"})

      assert InstanceConfig.load().deletion_grace_days == 30
      assert entries() == []

      assert {:ok, _values} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => "14"})

      assert [_one] = entries()

      assert {:ok, _values} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => "14"})

      assert {:error, %Ecto.Changeset{}} =
               InstanceConfig.save(scope, :deletion, %{"deletion_grace_days" => "0"})

      assert {:error, :sudo} =
               InstanceConfig.save(signed_in(scope, 21), :deletion, %{
                 "deletion_grace_days" => "7"
               })

      assert [_one] = entries()
      assert InstanceConfig.load().deletion_grace_days == 14
    end
  end

  describe "Apiary.InstanceConfig.Cache, each node's copy" do
    test "holds what the database has, reads it again on every save, and leaves when it stops",
         %{scope: scope} do
      assert Cache.cached() == :error
      start_supervised!(Cache)
      assert Cache.cached() == {:ok, InstanceConfig.load()}

      assert {:ok, _values} =
               InstanceConfig.save(scope, :invitations, %{"invitations_per_day" => "50"})

      eventually(fn -> assert {:ok, %{invitations_per_day: 50}} = Cache.cached() end)

      # Changed in the database without a save, the copy is what a value is read from.
      saved!(%{invitations_per_day: 7})
      assert Instance.invitations_per_day() == 50

      stop_supervised!(Cache)
      assert Cache.cached() == :error
      assert Instance.invitations_per_day() == 7
    end

    test "without it, each value reads the row" do
      assert Cache.cached() == :error
      saved!(%{deletion_grace_days: 7})
      assert Deletion.grace_days() == 7
      saved!(%{deletion_grace_days: 14})
      assert Deletion.grace_days() == 14
    end

    test "on a schema without the columns, nothing is saved" do
      # As with MIGRATE_ON_BOOT=false before bin/migrate has run this release's migration.
      Repo.query!("ALTER TABLE instance_settings DROP COLUMN invitations_per_day")
      assert InstanceConfig.load() == Map.new(InstanceConfig.keys(), &{&1, nil})
      assert Instance.invitations_per_day() == 20
    end
  end

  describe "the database's checks" do
    test "refuse what no save writes" do
      saved!(%{invitations_per_day: 1})

      for {field, value} <- [
            audit_retention_days: 29,
            audit_address_retention_days: 0,
            deletion_grace_days: 91,
            deletion_grace_days: 0,
            invitations_per_day: 0,
            machine_log_retention_days: 0,
            machine_log_retention_days: 366
          ] do
        assert_raise Postgrex.Error, ~r/instance_settings_#{field}_check/, fn ->
          Repo.transaction(fn -> Repo.update_all(Row, set: [{field, value}]) end)
        end
      end

      assert InstanceConfig.load().invitations_per_day == 1
    end
  end

  # Asserts `fun` within a few seconds: the cache reads the row again once the broadcast
  # reaches it.
  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(20)
      eventually(fun, tries - 1)
  end
end

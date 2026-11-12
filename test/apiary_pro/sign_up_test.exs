defmodule ApiaryPro.SignUpTest do
  @moduledoc """
  Who may sign up (`ApiaryPro.SignUp`): each setting, the environment's before the saved
  one before closed, empty as not set; the check of the environment at boot; the save,
  who may save and the instance's trail; and each node's copy (`ApiaryPro.SignUp.Cache`).
  """
  # Not async: the variables and the cache's copy are the whole node's, and hiding the
  # instance's organisation acts on the row every test shares.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.SignUpFixtures

  alias Apiary.Audit.Entry
  alias ApiaryPro.SignUp
  alias ApiaryPro.SignUp.{Cache, Row}

  # `scope` as a sign-in `minutes` ago leaves it (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in(scope, minutes \\ 0),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), -minutes, :minute))

  # Writes the row as it is, past the save's checks.
  defp saved!(values) do
    Repo.insert_all(
      Row,
      [Map.merge(%{id: true, updated_at: DateTime.utc_now()}, values)],
      on_conflict: {:replace, Map.keys(values)},
      conflict_target: :id
    )
  end

  # The trail's entries of `instance.change_sign_up` in the instance's organisation.
  defp entries do
    Repo.all(
      from e in Entry,
        where: e.action == "instance.change_sign_up",
        where: e.organisation_id == ^Apiary.Edition.instance_organisation_id(),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  setup do
    # The variables, whatever the suite's configuration set: none.
    unset_variables()
    :ok
  end

  describe "SIGNUP_ORGANISATIONS and SIGNUP_OPERATORS" do
    test "open or closed, closed when unset or blank, whatever the case and the spaces" do
      assert SignUp.parse(nil) == {:ok, :closed}
      assert SignUp.parse("") == {:ok, :closed}
      assert SignUp.parse("  ") == {:ok, :closed}
      assert SignUp.parse("open") == {:ok, :open}
      assert SignUp.parse(" Open ") == {:ok, :open}
      assert SignUp.parse("closed") == {:ok, :closed}
      assert SignUp.parse("CLOSED") == {:ok, :closed}

      for value <- ["true", "yes", "1", "opened", "invitation"] do
        assert {:error, reason} = SignUp.parse(value)
        assert reason =~ "open or closed"
      end
    end

    test "both closed by default: a later sign-up is offered no kind" do
      assert SignUp.boot!() == :ok
      assert SignUp.kinds() == []
      assert SignUp.settings() == %{organisation: :closed, operator: :closed}
      assert SignUp.source(:organisation) == :default
      assert SignUp.source(:operator) == :default
      refute Apiary.Edition.sign_up_open?()
    end

    test "each combination is the kinds it opens, in one order, whatever is saved" do
      saved!(%{organisations: "closed", operators: "open"})

      for {organisations, operators, kinds} <- [
            {"closed", "closed", []},
            {"open", "closed", [:organisation]},
            {"closed", "open", [:operator]},
            {" Open ", "OPEN", [:organisation, :operator]}
          ] do
        put_variables(organisations: organisations, operators: operators)

        assert SignUp.boot!() == :ok
        assert SignUp.kinds() == kinds
        assert SignUp.source(:organisation) == :env
        assert SignUp.source(:operator) == :env
        assert Apiary.Edition.sign_up_open?() == (kinds != [])
      end
    end

    test "set empty or blank is not set: the saved setting applies" do
      saved!(%{organisations: "open"})
      put_variables(organisations: "", operators: "  ")

      assert SignUp.env(:organisation) == nil
      assert SignUp.env(:operator) == nil
      assert SignUp.kinds() == [:organisation]
      assert SignUp.source(:organisation) == :saved
      assert SignUp.source(:operator) == :default
    end

    test "the environment wins, setting by setting" do
      saved!(%{organisations: "open", operators: "open"})
      put_variables(organisations: "closed")

      assert SignUp.kinds() == [:operator]
      assert SignUp.source(:organisation) == :env
      assert SignUp.source(:operator) == :saved
    end

    test "a value refused stops the boot, the edition's included, naming the variable" do
      put_variables(organisations: "yes")
      assert_raise ArgumentError, ~r/SIGNUP_ORGANISATIONS/, fn -> SignUp.boot!() end
      assert_raise ArgumentError, ~r/SIGNUP_ORGANISATIONS/, fn -> Apiary.Edition.boot!() end

      put_variables(operators: "maybe")
      assert_raise ArgumentError, ~r/SIGNUP_OPERATORS/, fn -> SignUp.boot!() end
    end
  end

  describe "save/2" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      %{scope: scope} = sign_up_fixture()
      assert Apiary.Access.instance_admin?(scope)
      %{scope: signed_in(scope)}
    end

    test "saves both settings, applies them at once and records the change", %{scope: scope} do
      assert {:ok, %{organisation: :open, operator: :open}} =
               SignUp.save(scope, %{"organisations" => "open", "operators" => "open"})

      assert SignUp.kinds() == [:organisation, :operator]
      assert SignUp.source(:organisation) == :saved

      assert [entry] = entries()
      assert entry.actor_id == scope.user.id
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      assert {entry.before, entry.after} ==
               {%{"organisations" => "closed", "operators" => "closed"},
                %{"organisations" => "open", "operators" => "open"}}

      # One setting changed: the entry names it alone.
      assert {:ok, %{organisation: :open, operator: :closed}} =
               SignUp.save(scope, %{"organisations" => "open", "operators" => "closed"})

      assert [_, entry] = entries()
      assert {entry.before, entry.after} == {%{"operators" => "open"}, %{"operators" => "closed"}}
    end

    test "a save that changes no setting in effect records nothing", %{scope: scope} do
      # The default saved as its value is no change, though the row now holds it.
      assert {:ok, _} =
               SignUp.save(scope, %{"organisations" => "closed", "operators" => "closed"})

      assert SignUp.load() == %{organisation: :closed, operator: :closed}
      assert SignUp.source(:organisation) == :saved
      assert entries() == []

      assert {:ok, _} = SignUp.save(scope, %{"organisations" => "closed"})
      assert entries() == []
    end

    test "leaves a setting the environment sets as it is, and one not given", %{scope: scope} do
      put_variables(organisations: "closed")

      assert {:ok, %{organisation: :closed, operator: :open}} =
               SignUp.save(scope, %{"organisations" => "open", "operators" => "open"})

      assert SignUp.load() == %{organisation: nil, operator: :open}
      assert [entry] = entries()
      assert {entry.before, entry.after} == {%{"operators" => "closed"}, %{"operators" => "open"}}
    end

    test "takes open or closed only", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               SignUp.save(scope, %{"organisations" => "maybe"})

      assert errors_on(changeset) == %{organisations: ["is invalid"]}
      assert SignUp.load() == %{organisation: nil, operator: nil}
      assert entries() == []
    end

    test "is an instance admin's, after a recent sign-in", %{scope: scope} do
      attrs = %{"organisations" => "open"}

      assert SignUp.save(signed_in(scope, 21), attrs) == {:error, :sudo}

      %{scope: member} = member_fixture(scope, :admin)
      assert SignUp.save(signed_in(member), attrs) == {:error, :forbidden}

      put_variables(organisations: "open")
      %{scope: stranger} = sign_up_fixture()
      unset_variables()
      assert SignUp.save(signed_in(stranger), attrs) == {:error, :forbidden}
      assert SignUp.save(nil, attrs) == {:error, :forbidden}

      assert SignUp.load() == %{organisation: nil, operator: nil}
      assert entries() == []
    end
  end

  describe "ApiaryPro.SignUp.Cache, each node's copy" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      %{scope: scope} = sign_up_fixture()
      %{scope: signed_in(scope)}
    end

    test "holds what the database has, reads it again on every save, and leaves when it stops",
         %{scope: scope} do
      assert Cache.cached() == :error
      start_supervised!(Cache)
      assert Cache.cached() == {:ok, SignUp.load()}

      assert {:ok, _settings} = SignUp.save(scope, %{"operators" => "open"})
      eventually(fn -> assert {:ok, %{operator: :open}} = Cache.cached() end)

      # Changed in the database without a save, the copy is what the kinds are read from.
      saved!(%{operators: "closed"})
      assert SignUp.kinds() == [:operator]

      stop_supervised!(Cache)
      assert Cache.cached() == :error
      assert SignUp.kinds() == []
    end

    test "without it, the kinds read the row" do
      assert Cache.cached() == :error
      saved!(%{organisations: "open"})
      assert SignUp.kinds() == [:organisation]
      saved!(%{organisations: "closed"})
      assert SignUp.kinds() == []
    end

    test "without the table, nothing is saved" do
      # As with MIGRATE_ON_BOOT=false before bin/migrate has run the migration that makes
      # it.
      Repo.query!("DROP TABLE instance_sign_up")
      assert SignUp.load() == %{organisation: nil, operator: nil}
      assert SignUp.kinds() == []
    end
  end

  test "the database holds one row, of open or closed" do
    saved!(%{organisations: "open"})

    assert_raise Postgrex.Error, ~r/instance_sign_up_one_row_check/, fn ->
      Repo.query!("INSERT INTO instance_sign_up (id, updated_at) VALUES (false, now())")
    end

    assert_raise Postgrex.Error, ~r/instance_sign_up_operators_check/, fn ->
      Repo.query!("UPDATE instance_sign_up SET operators = 'maybe'")
    end
  end

  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(20)
      eventually(fun, tries - 1)
  end
end

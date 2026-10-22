defmodule Apiary.Nodes.GatewayAddressMigrationTest do
  # The two migrations that hold a gateway's address to the contracts' `gateway_url`, run
  # down and up again inside the test's transaction, which rolls it all back. They change
  # the `nodes` table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @hold {20_261_022_200_000, Apiary.Repo.Migrations.HoldAGatewaySAddressToTheContracts,
         "hold_a_gateway_s_address_to_the_contracts"}
  @validate {20_261_022_200_100, Apiary.Repo.Migrations.ValidateAGatewaySContractsAddressCheck,
             "validate_a_gateway_s_contracts_address_check"}

  setup_all do
    for {version, migration, name} <- [@hold, @validate], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp set_url!(gateway, url) do
    Repo.query!("UPDATE nodes SET url = $2 WHERE id = $1", [Ecto.UUID.dump!(gateway.id), url])
  end

  defp rename!(gateway, name) do
    Repo.query!("UPDATE nodes SET name = $2 WHERE id = $1", [Ecto.UUID.dump!(gateway.id), name])
  end

  defp validated? do
    %{rows: [[validated]]} =
      Repo.query!(
        "SELECT convalidated FROM pg_constraint " <>
          "WHERE conrelid = 'nodes'::regclass AND conname = 'nodes_url_check'"
      )

    validated
  end

  # An address the check before took and the contracts refuse: a trailing dot. The check
  # before held a host to 253 characters, so no address it took is over 300 characters.
  @trailing_dot "https://gateway.example."

  test "down and up again: the new check holds once validated, a trailing dot refused" do
    %{scope: scope} = sign_up_fixture()
    gateway = gateway_fixture(scope)

    down!(@validate)
    down!(@hold)
    assert %{num_rows: 1} = set_url!(gateway, @trailing_dot)
    assert %{num_rows: 1} = set_url!(gateway, "https://gateway.example")

    up!(@hold)
    refute validated?()
    up!(@validate)
    assert validated?()

    assert_raise Postgrex.Error, ~r/nodes_url_check/, fn ->
      Repo.transaction(fn -> set_url!(gateway, @trailing_dot) end)
    end
  end

  test "a gateway with a trailing dot before the migration: no write of its row passes until its address is fixed, and the validation stops and names it" do
    %{scope: scope} = sign_up_fixture()
    gateway = gateway_fixture(scope)
    fine = gateway_fixture(scope)

    down!(@validate)
    down!(@hold)
    set_url!(gateway, @trailing_dot)

    # Added NOT VALID, the check leaves the row as it is, and refuses every later write
    # of it, its address unchanged, as a rename or a deletion makes.
    up!(@hold)

    assert_raise Postgrex.Error, ~r/nodes_url_check/, fn ->
      Repo.transaction(fn -> rename!(gateway, "edge-2") end)
    end

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.up(Repo, elem(@validate, 0), elem(@validate, 1), @options)
      end

    assert error.postgres.code == :check_violation

    assert error.postgres.message =~
             "Give the gateways #{gateway.public_id} an address of https://, a host and an " <>
               "optional port, at most 300 characters and with no trailing dot, then run " <>
               "the migrations again"

    refute error.postgres.message =~ fine.public_id
    refute validated?()

    set_url!(gateway, "https://gateway.example")
    up!(@validate)
    assert validated?()
    assert %{num_rows: 1} = rename!(gateway, "edge-2")
  end
end

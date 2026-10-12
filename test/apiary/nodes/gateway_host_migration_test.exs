defmodule Apiary.Nodes.GatewayHostMigrationTest do
  # The two migrations that hold a gateway's host to a DNS name or an IP address, run down
  # and up again inside the test's transaction, which rolls it all back. They change the
  # `nodes` table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @hold {20_261_011_160_700, Apiary.Repo.Migrations.HoldAGatewaySHostToANameOrAnIpAddress,
         "hold_a_gateway_s_host_to_a_name_or_an_ip_address"}
  @validate {20_261_011_160_800, Apiary.Repo.Migrations.ValidateAGatewaySHostCheck,
             "validate_a_gateway_s_host_check"}

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

  defp validated? do
    %{rows: [[validated]]} =
      Repo.query!(
        "SELECT convalidated FROM pg_constraint " <>
          "WHERE conrelid = 'nodes'::regclass AND conname = 'nodes_url_check'"
      )

    validated
  end

  @bad "https://edge.example.com;rm$IFS-rf$IFS~"

  test "down and up again: the old check comes back, and the new one holds once validated" do
    %{scope: scope} = sign_up_fixture()
    gateway = gateway_fixture(scope)

    down!(@validate)
    down!(@hold)

    # The old check lets the host's other characters through.
    assert %{num_rows: 1} = set_url!(gateway, @bad)
    assert %{num_rows: 1} = set_url!(gateway, "https://gateway.example")

    up!(@hold)
    refute validated?()
    up!(@validate)
    assert validated?()

    assert_raise Postgrex.Error, ~r/nodes_url_check/, fn ->
      Repo.transaction(fn -> set_url!(gateway, @bad) end)
    end
  end

  test "the validation refuses while a gateway's host is outside the check, and names it" do
    %{scope: scope} = sign_up_fixture()
    gateway = gateway_fixture(scope)
    fine = gateway_fixture(scope)

    down!(@validate)
    down!(@hold)
    set_url!(gateway, @bad)

    # Added NOT VALID, the check leaves the row as it is.
    up!(@hold)

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.up(Repo, elem(@validate, 0), elem(@validate, 1), @options)
      end

    assert error.postgres.code == :check_violation

    assert error.postgres.message =~
             "nodes_url_check: the gateways #{gateway.public_id} have an address whose host " <>
               "is not a DNS name, an IPv4 address or an IPv6 address in brackets"

    refute error.postgres.message =~ fine.public_id
    refute validated?()

    set_url!(gateway, "https://gateway.example")
    up!(@validate)
    assert validated?()
  end
end

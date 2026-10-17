defmodule Apiary.Nodes.AdapterMigrationsTest do
  # The three migrations that make an adapter a kind of node of the instance, connect an
  # organisation to one, and validate their checks, run down and up again inside the test's
  # transaction, which rolls it all back, with the later ones that rest on the connections
  # (`@listing`, `@again`, `@items`, `@collections`, then `@ticket`), down first and up
  # last. They change `nodes`, `access_keys` and `access_key_enrolment_codes` under every
  # other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  # The adapters are made where the feature they belong to is on.
  @moduletag needs: :factory

  @kind {20_261_015_131_000, Apiary.Repo.Migrations.MakeAnAdapterAKindOfNode,
         "make_an_adapter_a_kind_of_node"}
  @connect {20_261_015_131_100, Apiary.Repo.Migrations.ConnectAnOrganisationToAnAdapter,
            "connect_an_organisation_to_an_adapter"}
  @validate {20_261_015_131_200, Apiary.Repo.Migrations.ValidateAnAdapterSChecks,
             "validate_an_adapter_s_checks"}
  @ticket {20_261_017_090_000, Apiary.Repo.Migrations.NameAWorkItemSTicketByItsConnection,
           "name_a_work_item_s_ticket_by_its_connection"}
  @collections {20_261_017_170_300, Apiary.Repo.Migrations.KeepAnAdapterSCollections,
                "keep_an_adapter_s_collections"}
  @items {20_261_017_190_000, Apiary.Repo.Migrations.KeepSourceItems, "keep_source_items"}
  @again {20_261_017_190_100, Apiary.Repo.Migrations.TakeWorkItemsInAgain,
          "take_work_items_in_again"}
  @listing {20_261_017_190_500, Apiary.Repo.Migrations.KeepWhenAConnectionSListingCompleted,
            "keep_when_a_connection_s_listing_completed"}

  @tables ~w(nodes access_keys access_key_enrolment_codes node_instances)
  @checks ~w(access_keys_place_check access_key_enrolment_codes_place_check
             access_keys_node_fkey access_keys_enrolment_code_fkey
             access_key_enrolment_codes_node_fkey)

  setup_all do
    for {version, migration, name} <- [
          @kind,
          @connect,
          @validate,
          @ticket,
          @collections,
          @items,
          @again,
          @listing
        ],
        not Code.ensure_loaded?(migration) do
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

  defp down_all! do
    down!(@listing)
    down!(@again)
    down!(@items)
    down!(@collections)
    down!(@ticket)
    down!(@validate)
    down!(@connect)
    down!(@kind)
  end

  defp up_all! do
    up!(@kind)
    up!(@connect)
    up!(@validate)
    up!(@ticket)
    up!(@collections)
    up!(@items)
    up!(@again)
    up!(@listing)
  end

  # Each table's `organisation_id`, whether it may be NULL.
  defp nullable do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name, is_nullable FROM information_schema.columns " <>
          "WHERE column_name = 'organisation_id' AND table_name = ANY($1)",
        [@tables]
      )

    Map.new(rows, fn [table, nullable] -> {table, nullable == "YES"} end)
  end

  defp constraints do
    %{rows: rows} =
      Repo.query!("SELECT conname FROM pg_constraint WHERE conname = ANY($1)", [@checks])

    rows |> List.flatten() |> Enum.sort()
  end

  # The trigger's columns on each table: what a change of fires it.
  defp trigger_fires_on_organisation? do
    %{rows: rows} =
      Repo.query!(
        "SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname LIKE '%_node_place_matches'"
      )

    assert length(rows) == 3
    Enum.all?(rows, fn [definition] -> definition =~ "organisation_id" end)
  end

  test "down and up again: an organisation for every row, then none for an adapter's alone" do
    %{scope: scope} = sign_up_fixture()
    node_fixture(scope)

    assert nullable() == %{
             "nodes" => true,
             "access_keys" => true,
             "access_key_enrolment_codes" => true,
             "node_instances" => false
           }

    assert constraints() == Enum.sort(@checks)
    assert trigger_fires_on_organisation?()

    down_all!()

    assert nullable() |> Map.values() |> Enum.uniq() == [false]
    assert constraints() == []
    refute trigger_fires_on_organisation?()

    up_all!()

    assert nullable()["nodes"]
    assert constraints() == Enum.sort(@checks)
    assert trigger_fires_on_organisation?()

    adapter = adapter_fixture()
    assert adapter.organisation_id == nil

    assert_raise Postgrex.Error, ~r/nodes_place_check/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE nodes SET organisation_id = NULL WHERE kind = 'node'")
      end)
    end
  end

  test "rolled back, the adapter's kind refuses to go while an adapter row is there" do
    adapter_fixture()

    down!(@listing)
    down!(@again)
    down!(@items)
    down!(@collections)
    down!(@ticket)
    down!(@validate)
    down!(@connect)

    assert_raise Postgrex.Error, ~r/nodes holds adapters/, fn ->
      Ecto.Migrator.down(Repo, elem(@kind, 0), elem(@kind, 1), @options)
    end

    assert nullable()["nodes"]
    up!(@connect)
    up!(@validate)
    up!(@ticket)
    up!(@collections)
    up!(@items)
    up!(@again)
    up!(@listing)
  end
end

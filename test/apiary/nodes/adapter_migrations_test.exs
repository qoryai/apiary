defmodule Apiary.Nodes.AdapterMigrationsTest do
  # The three migrations that make an adapter a kind of node of the instance, connect an
  # organisation to one, and validate their checks, run down and up again inside the test's
  # transaction, which rolls it all back, with the later ones that rest on the connections
  # or on the place of a node (`@grant_rule`, `@grant_account`, `@run_credentials`, `@linked_passes`,
  # `@linked_pass`, `@grants`, `@instance`, `@hold`, `@prebuilds`, `@environments`, `@environment_ref`,
  # `@left_out`, `@listed`, `@listing`, `@again`, `@items`, `@collections`, then
  # `@ticket`), down first and up last. `@hold` stays down, as the migrations between it and `@prebuilds` that it
  # changes do not run again. `@grants` and `@linked_passes` run down because their foreign
  # keys rest on the index of `adapter_connections` on `id`, `organisation_id` and
  # `adapter_id`, which `@collections` drops; `@linked_pass` runs down between them. The
  # three stay down, as the test checks nothing of theirs, and the rollback restores them.
  # So does `@run_credentials`, whose table has a foreign key to `adapter_connections`,
  # and `@grant_account` and `@grant_rule`, whose foreign keys from `source_collections`
  # and `grant_rules` rest on `adapter_grants`, which `@grants` drops.
  # The migrations change `nodes`, `access_keys` and `access_key_enrolment_codes` under
  # every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

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
  @collections {20_261_017_141_000, Apiary.Repo.Migrations.KeepAnAdapterSCollections,
                "keep_an_adapter_s_collections"}
  @items {20_261_017_143_000, Apiary.Repo.Migrations.KeepSourceItems, "keep_source_items"}
  @again {20_261_017_144_000, Apiary.Repo.Migrations.TakeWorkItemsInAgain,
          "take_work_items_in_again"}
  @listing {20_261_017_145_000, Apiary.Repo.Migrations.KeepWhenAConnectionSListingCompleted,
            "keep_when_a_connection_s_listing_completed"}
  @listed {20_261_017_150_000, Apiary.Repo.Migrations.KeepWhenAnItemWasLastListed,
           "keep_when_an_item_was_last_listed"}
  @left_out {20_261_017_151_000, Apiary.Repo.Migrations.KeepWhenACompleteSetLeftACommentOut,
             "keep_when_a_complete_set_left_a_comment_out"}

  @environment_ref {20_261_017_154_000, Apiary.Repo.Migrations.KeepACollectionSEnvironmentRef,
                    "keep_a_collection_s_environment_ref"}
  @environments {20_261_017_155_000, Apiary.Repo.Migrations.KeepEnvironments, "keep_environments"}
  @prebuilds {20_261_017_160_000, Apiary.Repo.Migrations.QueuePrebuilds, "queue_prebuilds"}
  @hold {20_261_023_090_000, Apiary.Repo.Migrations.HoldRunsForTheirEnvironmentBuild,
         "hold_runs_for_their_environment_build"}
  @instance {20_261_024_100_000, Apiary.Repo.Migrations.KeepAPoolAndAGatewayAtTheInstance,
             "keep_a_pool_and_a_gateway_at_the_instance"}

  @grants {20_261_025_120_000, Apiary.Repo.Migrations.KeepAnOrganisationSGrants,
           "keep_an_organisation_s_grants"}
  @linked_pass {20_261_025_120_100, Apiary.Repo.Migrations.KeepAConnectionSLinkedPass,
                "keep_a_connection_s_linked_pass"}
  @linked_passes {20_261_025_120_200, Apiary.Repo.Migrations.KeepEachLinkedPassOfAConnection,
                  "keep_each_linked_pass_of_a_connection"}

  @run_credentials {20_261_025_160_500, Apiary.Repo.Migrations.KeepEachRunSCredentialEntries,
                    "keep_each_run_s_credential_entries"}

  @grant_account {20_261_025_160_700, Apiary.Repo.Migrations.KeepAGrantSAccountAndItsCollections,
                  "keep_a_grant_s_account_and_its_collections"}

  @grant_rule {20_261_029_141_700, Apiary.Repo.Migrations.KeepAGrantSRule, "keep_a_grant_s_rule"}

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
          @listing,
          @listed,
          @left_out,
          @environment_ref,
          @environments,
          @prebuilds,
          @hold,
          @instance,
          @grants,
          @linked_pass,
          @linked_passes,
          @run_credentials,
          @grant_account,
          @grant_rule
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
    down!(@grant_rule)
    down!(@grant_account)
    down!(@run_credentials)
    down!(@linked_passes)
    down!(@linked_pass)
    down!(@grants)
    down!(@instance)
    down!(@hold)
    down!(@prebuilds)
    down!(@environments)
    down!(@environment_ref)
    down!(@left_out)
    down!(@listed)
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
    up!(@listed)
    up!(@left_out)
    up!(@environment_ref)
    up!(@environments)
    up!(@prebuilds)
    up!(@instance)
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
             "node_instances" => true
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

    assert_raise Postgrex.Error, ~r/nodes_place_fixed/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE nodes SET organisation_id = NULL WHERE kind = 'node'")
      end)
    end
  end

  test "rolled back, the adapter's kind refuses to go while an adapter row is there" do
    adapter_fixture()

    down!(@grant_rule)
    down!(@grant_account)
    down!(@run_credentials)
    down!(@linked_passes)
    down!(@linked_pass)
    down!(@grants)
    down!(@hold)
    down!(@prebuilds)
    down!(@environments)
    down!(@environment_ref)
    down!(@left_out)
    down!(@listed)
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
    up!(@listed)
    up!(@left_out)
    up!(@environment_ref)
    up!(@environments)
    up!(@prebuilds)
  end
end

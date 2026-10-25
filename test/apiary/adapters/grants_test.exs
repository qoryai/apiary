defmodule Apiary.Adapters.GrantsTest do
  # The grants of an organisation's connections to the instance's adapters, and the table
  # that keeps them.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters.Grant
  alias Apiary.Repo

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{
      scope: scope,
      adapter: connectable.adapter,
      pair: connectable.pair,
      key: connectable.access_key
    }
  end

  describe "the table" do
    defp insert(attrs) do
      now = DateTime.utc_now()

      Repo.insert_all(Grant, [
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            public_id: Apiary.PublicId.generate("ag"),
            grant_ref: "G_1",
            state: :live,
            pass_nonce: :crypto.strong_rand_bytes(16),
            granted_at: now,
            inserted_at: now,
            updated_at: now
          },
          attrs
        )
      ])
    end

    defp refused(fun) do
      %Postgrex.Error{postgres: %{constraint: constraint}} = assert_raise(Postgrex.Error, fun)
      constraint
    end

    test "a grant stays with its connection's organisation and adapter", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _nonce} = connection_fixture(scope, adapter)
      %{scope: other} = sign_up_fixture()
      second = adapter_fixture()

      base = %{
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        connection_id: connection.id
      }

      assert {1, _} = insert(base)

      for change <- [
            %{organisation_id: other.organisation.id, grant_ref: "G_2"},
            %{adapter_id: second.id, grant_ref: "G_3"}
          ] do
        assert refused(fn -> insert(Map.merge(base, change)) end) ==
                 "adapter_grants_connection_id_fkey"
      end
    end

    test "one live grant per adapter and ref, one per pass, and its states hold together", %{
      scope: scope,
      adapter: adapter
    } do
      {connection, _nonce} = connection_fixture(scope, adapter)
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, adapter)
      nonce = :crypto.strong_rand_bytes(16)

      base = %{
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        connection_id: connection.id
      }

      assert {1, _} = insert(Map.put(base, :pass_nonce, nonce))

      # The same ref, live, under another organisation's connection of the adapter.
      assert refused(fn ->
               insert(%{
                 organisation_id: other.organisation.id,
                 adapter_id: adapter.id,
                 connection_id: theirs.id
               })
             end) == "adapter_grants_live_index"

      # The same pass for a second grant of the connection.
      assert refused(fn -> insert(Map.merge(base, %{grant_ref: "G_2", pass_nonce: nonce})) end) ==
               "adapter_grants_connection_id_pass_nonce_index"

      now = DateTime.utc_now()
      ended = %{state: :ended, ended_at: now, ended_reason: :connection_ended}

      # An ended grant leaves its ref free.
      assert {1, _} = insert(Map.merge(base, ended))

      for {attrs, constraint} <- [
            {Map.put(ended, :public_id, "ag_x"), "adapter_grants_public_id_check"},
            {Map.put(ended, :grant_ref, ""), "adapter_grants_grant_ref_check"},
            {Map.put(ended, :grant_ref, String.duplicate("g", 201)),
             "adapter_grants_grant_ref_check"},
            {Map.put(ended, :pass_nonce, <<0::120>>), "adapter_grants_pass_nonce_check"},
            {%{ended | state: :live}, "adapter_grants_state_check"},
            {%{state: :ended, grant_ref: "G_3"}, "adapter_grants_state_check"},
            {%{state: :ended, ended_at: now}, "adapter_grants_ended_reason_check"},
            {%{grant_ref: "G_4", ended_reason: :connection_ended},
             "adapter_grants_ended_reason_check"}
          ] do
        assert refused(fn -> insert(Map.merge(base, attrs)) end) == constraint, inspect(attrs)
      end

      assert refused(fn ->
               Repo.update_all(from(g in "adapter_grants", where: g.pass_nonce == ^nonce),
                 set: [ended_reason: "adapter_reported"]
               )
             end) == "adapter_grants_ended_reason_check"
    end
  end
end

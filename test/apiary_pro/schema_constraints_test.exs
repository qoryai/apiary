defmodule ApiaryPro.SchemaConstraintsTest do
  # The database's rules of the edition's tables, asked in raw SQL so that no
  # changeset stands between the write and the database: a tenant's kind, the instance
  # organisation, the managing relationship and a suspension, a suspended account's row,
  # the organisation's policy and its rules, the organisation's variables, and the
  # features a grant may name.
  #
  # Async: the rules of the instance organisation are asked of a fresh tenant, never of
  # the suite's committed one, whose row no test here locks. Postgres evaluates a check
  # before the unique index, so a fresh tenant flagged against a check is refused by the
  # check, and one flagged within the checks meets the committed instance organisation in
  # the index.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  # A fresh organisation, with the tenant the edition's sign-up writes: its id as the
  # database takes it.
  defp organisation! do
    %{organisation: organisation} = sign_up_fixture()
    Ecto.UUID.dump!(organisation.id)
  end

  defp operator! do
    id = organisation!()
    update!(id, "kind = 'operator'")
    id
  end

  defp client!(operator) do
    id = organisation!()
    make_client!(id, operator)
    id
  end

  defp make_client!(id, operator) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE tenants SET operator_id = $2, operator_since = now() " <>
                 "WHERE organisation_id = $1",
               [id, operator]
             )
  end

  # Sets `assignments` on the tenant of the organisation `id`, which must be there.
  defp update!(id, assignments) do
    assert %{num_rows: 1} =
             Repo.query!("UPDATE tenants SET #{assignments} WHERE organisation_id = $1", [id])
  end

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  describe "tenants" do
    test "a kind is organisation or operator, and nothing else" do
      id = organisation!()

      update!(id, "kind = 'operator'")
      update!(id, "kind = 'organisation'")
      refused("tenants_kind_check", fn -> update!(id, "kind = 'bank'") end)
      refused("tenants_kind_check", fn -> update!(id, "kind = 'instance_organisation'") end)
    end

    test "one tenant at most is the instance organisation, and the suite's instance has it" do
      # Of either kind: no check stands before the index for an organisation or an
      # operator, so each flagged meets the committed instance organisation there.
      for id <- [organisation!(), operator!()] do
        refused("tenants_one_instance_organisation_index", fn ->
          update!(id, "instance_organisation = true")
        end)
      end
    end

    test "eight checks, and none holds the instance organisation's kind" do
      checks =
        Repo.query!(
          "SELECT conname FROM pg_constraint " <>
            "WHERE conrelid = 'tenants'::regclass AND contype = 'c' ORDER BY conname"
        ).rows
        |> List.flatten()

      assert checks == [
               "tenants_client_kind_check",
               "tenants_instance_organisation_not_client",
               "tenants_instance_organisation_not_suspended",
               "tenants_kind_check",
               "tenants_model_chain_check",
               "tenants_model_chain_operator_check",
               "tenants_operator_since_check",
               "tenants_suspension_check"
             ]
    end

    test "an organisation or an operator may be suspended, and the instance organisation never" do
      for id <- [organisation!(), operator!()] do
        update!(id, "suspended_at = now()")

        refused("tenants_instance_organisation_not_suspended", fn ->
          update!(id, "instance_organisation = true")
        end)
      end
    end

    test "a client may have an operator, and the instance organisation never" do
      client = client!(operator!())

      refused("tenants_instance_organisation_not_client", fn ->
        update!(client, "instance_organisation = true")
      end)
    end

    test "a client is of the kind organisation, so no operator is a client" do
      operator = operator!()
      client = client!(operator)

      refused("tenants_client_kind_check", fn -> update!(client, "kind = 'operator'") end)
      refused("tenants_client_kind_check", fn -> make_client!(operator!(), operator) end)
    end

    test "a client's operator is an organisation of the kind operator" do
      id = organisation!()

      for operator <- [organisation!(), Ecto.UUID.bingenerate()] do
        refused("tenants_operator_fkey", fn -> make_client!(id, operator) end)
      end
    end

    test "an operator keeps its kind and its row while it has clients" do
      operator = operator!()
      client = client!(operator)

      refused("tenants_operator_fkey", fn -> update!(operator, "kind = 'organisation'") end)

      refused("tenants_operator_fkey", fn ->
        Repo.query!("DELETE FROM organisations WHERE id = $1", [operator])
      end)

      update!(client, "operator_id = NULL, operator_since = NULL")
      update!(operator, "kind = 'organisation'")
    end

    test "operator_since is set exactly while there is an operator" do
      client = client!(operator!())

      refused("tenants_operator_since_check", fn -> update!(client, "operator_since = NULL") end)
      refused("tenants_operator_since_check", fn -> update!(client, "operator_id = NULL") end)

      update!(client, "operator_id = NULL, operator_since = NULL")

      refused("tenants_operator_since_check", fn -> update!(client, "operator_since = now()") end)
    end

    test "a suspender only with a suspension" do
      %{organisation: organisation, user: user} = sign_up_fixture()
      id = Ecto.UUID.dump!(organisation.id)
      user_id = Ecto.UUID.dump!(user.id)

      refused("tenants_suspension_check", fn ->
        Repo.query!("UPDATE tenants SET suspended_by_id = $2 WHERE organisation_id = $1", [
          id,
          user_id
        ])
      end)

      assert %{num_rows: 1} =
               Repo.query!(
                 "UPDATE tenants SET suspended_at = now(), suspended_by_id = $2 " <>
                   "WHERE organisation_id = $1",
                 [id, user_id]
               )
    end
  end

  # An account nothing else references, so that its row may be deleted: an account is
  # otherwise never deleted, only erased, and this asks the database's key alone.
  defp account! do
    id = Ecto.UUID.bingenerate()

    Repo.query!(
      "INSERT INTO users (id, email, inserted_at, updated_at) VALUES ($1, $2, now(), now())",
      [id, "suspended-#{System.unique_integer([:positive])}@example.com"]
    )

    id
  end

  defp suspend!(user_id) do
    Repo.query!(
      "INSERT INTO account_suspensions (user_id, suspended_at) VALUES ($1, now())",
      [user_id]
    )
  end

  describe "account_suspensions" do
    test "one row per account" do
      user_id = account!()
      suspend!(user_id)

      refused("account_suspensions_pkey", fn -> suspend!(user_id) end)
    end

    test "the row goes with its account" do
      user_id = account!()
      suspend!(user_id)

      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM account_suspensions WHERE user_id = $1", [
                 user_id
               ])
    end
  end

  describe "organisation_policies" do
    test "one row per organisation, which goes with it" do
      id = organisation!()
      policy!(id)

      refused("organisation_policies_organisation_id_index", fn -> policy!(id) end)

      Repo.query!("DELETE FROM organisations WHERE id = $1", [id])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM organisation_policies WHERE organisation_id = $1",
                 [id]
               )
    end
  end

  describe "organisation_policy_rules" do
    test "one rule per host and organisation, which goes with it" do
      id = organisation!()
      rule!(id, "allow", "api.example", ["/v1/*"])
      rule!(organisation!(), "deny", "api.example", nil)

      refused("organisation_policy_rules_host_index", fn ->
        rule!(id, "deny", "api.example", nil)
      end)

      Repo.query!("DELETE FROM organisations WHERE id = $1", [id])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM organisation_policy_rules WHERE organisation_id = $1",
                 [id]
               )
    end

    test "a rule allows or denies, and a deny has no paths" do
      id = organisation!()

      refused("organisation_policy_rules_action_check", fn ->
        rule!(id, "observe", "a.example", nil)
      end)

      refused("organisation_policy_rules_deny_paths_check", fn ->
        rule!(id, "deny", "b.example", ["/v1/*"])
      end)

      rule!(id, "deny", "b.example", nil)
      rule!(id, "allow", "c.example", [])
    end
  end

  describe "organisation_variables" do
    test "one name per organisation whatever its case, which goes with it" do
      id = organisation!()
      variable!(id, "LOG_LEVEL", "info")
      variable!(organisation!(), "log_level", "debug")

      refused("organisation_variables_name_index", fn -> variable!(id, "log_level", "debug") end)

      Repo.query!("DELETE FROM organisations WHERE id = $1", [id])

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM organisation_variables WHERE organisation_id = $1",
                 [id]
               )
    end

    test "a name keeps the variable's rule, and a value is one line of at most 4096 bytes" do
      id = organisation!()

      for name <- ["1ST", "API-BASE-URL", "LOG LEVEL", String.duplicate("A", 129), ""] do
        refused("organisation_variables_name_format", fn -> variable!(id, name, "x") end)
      end

      for value <- ["one\ntwo", "one\rtwo", String.duplicate("x", 4097)] do
        refused("organisation_variables_value_check", fn ->
          variable!(id, "API_BASE_URL", value)
        end)
      end

      variable!(id, "_PRIVATE", "")
      variable!(id, String.duplicate("A", 128), String.duplicate("x", 4096))
    end
  end

  describe "feature_grants" do
    test "a grant names a feature there is, the organisation's policy and variables among them" do
      id = organisation!()

      for feature <-
            ~w(observability security managed_organisations organisation_policy organisation_variables) do
        grant!(organisation!(), feature)
      end

      refused("feature_grants_feature_check", fn -> grant!(id, "dispatch") end)
      # A feature the editions no longer have.
      refused("feature_grants_feature_check", fn -> grant!(id, "factory") end)
    end
  end

  defp policy!(organisation) do
    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO organisation_policies (id, organisation_id, inserted_at, updated_at) " <>
                 "VALUES ($1, $2, now(), now())",
               [Ecto.UUID.bingenerate(), organisation]
             )
  end

  defp rule!(organisation, action, host, paths) do
    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO organisation_policy_rules " <>
                 "(id, organisation_id, action, host, paths, inserted_at, updated_at) " <>
                 "VALUES ($1, $2, $3, $4, $5, now(), now())",
               [Ecto.UUID.bingenerate(), organisation, action, host, paths]
             )
  end

  defp variable!(organisation, name, value) do
    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO organisation_variables " <>
                 "(id, organisation_id, name, value, inserted_at, updated_at) " <>
                 "VALUES ($1, $2, $3, $4, now(), now())",
               [Ecto.UUID.bingenerate(), organisation, name, value]
             )
  end

  defp grant!(organisation, feature) do
    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO feature_grants (id, organisation_id, feature, granted, inserted_at) " <>
                 "VALUES ($1, $2, $3, false, now())",
               [Ecto.UUID.bingenerate(), organisation, feature]
             )
  end
end

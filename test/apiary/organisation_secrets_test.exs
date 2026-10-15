defmodule Apiary.OrganisationSecretsTest do
  # The stored secrets of an organisation, those without a workspace (`Apiary.Secrets`):
  # what the core answers without an edition that grants them, and what they are where one
  # does (`Apiary.EditionStubs.GrantsOrganisationSecrets`).
  use Apiary.DataCase, async: true

  @moduletag needs: :secrets

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Audit, Edition, EditionStubs, KeyDerivation, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Secrets.{Cipher, DataKey, OrganisationDataKey, Secret, Value}

  @value "ghp_exampleTokenValue0123456789"

  defmodule CoreAnswers do
    @moduledoc false
    # The core's answer, whatever edition the suite is configured with.
    def organisation_secrets(scope, verb),
      do: Apiary.Edition.Core.organisation_secrets(scope, verb)
  end

  setup do
    owner = sign_up_fixture()

    %{
      owner: owner,
      scope: owner.scope,
      organisation: owner.organisation,
      workspace: owner.scope.workspace
    }
  end

  defp grant, do: Edition.put_test_stub(EditionStubs.GrantsOrganisationSecrets)

  defp create!(scope, attrs) do
    {:ok, secret} = Secrets.create_organisation_secret(scope, Map.merge(%{value: @value}, attrs))
    secret
  end

  defp create_in_workspace!(scope, attrs) do
    {:ok, secret} = Secrets.create_secret(scope, Map.merge(%{value: @value}, attrs))
    secret
  end

  defp reveal(organisation, secret, value_id \\ nil),
    do: Secrets.reveal_for_sealing(organisation, secret.public_id, value_id)

  defp row!(secret, value_id) do
    query = from v in Value, where: v.secret_id == ^secret.id

    query =
      if value_id,
        do: where(query, [v], v.value_id == ^value_id),
        else: where(query, [v], is_nil(v.value_id))

    Repo.one!(query)
  end

  defp organisation_keys(organisation),
    do: Repo.all(from k in OrganisationDataKey, where: k.organisation_id == ^organisation.id)

  defp trail(secret),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^secret.id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp dump(id), do: Ecto.UUID.dump!(id)

  describe "without an edition that grants them" do
    test "the core answers :not_found for every verb, :seal with a nil scope included",
         %{scope: scope} do
      for verb <- [:read, :write, :use] do
        assert Edition.Core.organisation_secrets(scope, verb) == {:error, :not_found}
      end

      assert Edition.Core.organisation_secrets(nil, :seal) == {:error, :not_found}
    end

    test "every entry of an organisation's secrets answers :not_found, and nothing is written",
         %{scope: scope, organisation: organisation} do
      # One made where they are granted, then the core's answer.
      grant()
      secret = create!(scope, %{name: "API_KEY"})
      Edition.put_test_stub(CoreAnswers)

      assert Secrets.list_organisation_secrets(scope) == {:error, :not_found}
      assert Secrets.get_organisation_secret(scope, secret.public_id) == {:error, :not_found}
      assert Secrets.list_uses(scope, [secret]) == {:error, :not_found}

      assert Secrets.create_organisation_secret(scope, %{name: "OTHER", value: "x"}) ==
               {:error, :not_found}

      assert Secrets.update_secret(scope, secret, %{name: "RENAMED"}) == {:error, :not_found}
      assert Secrets.set_value(scope, secret, nil, "x") == {:error, :not_found}

      assert Secrets.add_value(scope, secret, %{value_id: "a", value: "x", first_value_id: "b"}) ==
               {:error, :not_found}

      assert Secrets.rename_value(scope, secret, nil, "a") == {:error, :not_found}
      assert Secrets.delete_value(scope, secret, nil) == {:error, :not_found}
      assert Secrets.delete_secret(scope, secret) == {:error, :not_found}
      assert reveal(organisation, secret) == {:error, :not_found}

      assert [%Secret{name: "API_KEY", workspace_id: nil}] =
               Repo.all(from s in Secret, where: s.organisation_id == ^organisation.id)

      assert length(trail(secret)) == 1
    end

    test "a workspace's secrets are as they were", %{scope: scope, workspace: workspace} do
      Edition.put_test_stub(CoreAnswers)
      secret = create_in_workspace!(scope, %{name: "API_KEY"})

      assert {:ok, [%Secret{name: "API_KEY"}]} = Secrets.list_secrets(scope)
      assert Secrets.list_uses(scope, [secret]) == {:ok, %{secret.id => []}}
      assert Secrets.reveal_for_sealing(workspace, secret.public_id, nil) == {:ok, @value}
    end
  end

  describe "where an edition grants them" do
    setup do
      grant()
    end

    test "a secret round-trips, its values never shown, and only reveal_for_sealing/3 gives one back",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "GITHUB_TOKEN", note: "Opens pull requests"})

      assert %Secret{workspace_id: nil, name: "GITHUB_TOKEN", note: "Opens pull requests"} =
               secret

      assert secret.organisation_id == organisation.id
      assert [%Value{value_id: nil, value: nil, nonce: nil, ciphertext: nil}] = secret.values

      assert {:ok, [listed]} = Secrets.list_organisation_secrets(scope)
      assert listed.id == secret.id
      assert listed.created_by_id == scope.user.id
      assert [%Value{value: nil, nonce: nil, ciphertext: nil}] = listed.values

      assert {:ok, got} = Secrets.get_organisation_secret(scope, secret.public_id)
      assert got.id == secret.id
      assert Secrets.get_organisation_secret(scope, secret.id) == {:error, :not_found}
      assert Secrets.get_organisation_secret(scope, nil) == {:error, :not_found}

      assert Secrets.list_uses(scope, [secret]) == {:ok, %{secret.id => []}}
      assert reveal(organisation, secret) == {:ok, @value}
    end

    test "every change works on them, each value under its value id",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "KEYS", note: "Deploys"})
      assert {:ok, secret} = Secrets.update_secret(scope, secret, %{note: "Deploys the site"})
      assert secret.note == "Deploys the site"
      assert {:ok, secret} = Secrets.set_value(scope, secret, nil, "second value")
      assert reveal(organisation, secret) == {:ok, "second value"}

      assert {:ok, secret} =
               Secrets.add_value(scope, secret, %{
                 value_id: "bot",
                 value: "bot value",
                 first_value_id: "main"
               })

      assert reveal(organisation, secret, "main") == {:ok, "second value"}
      assert reveal(organisation, secret, "bot") == {:ok, "bot value"}

      assert {:ok, secret} = Secrets.rename_value(scope, secret, "bot", "robot")
      assert reveal(organisation, secret, "robot") == {:ok, "bot value"}
      assert reveal(organisation, secret, "bot") == {:error, :not_found}

      assert {:ok, secret} = Secrets.delete_value(scope, secret, "robot")
      assert Secrets.delete_value(scope, secret, "main") == {:error, :last_value}
      assert {:ok, _} = Secrets.delete_secret(scope, secret)
      assert Secrets.list_organisation_secrets(scope) == {:ok, []}
    end

    test "several values at once", %{scope: scope, organisation: organisation} do
      assert {:ok, secret} =
               Secrets.create_organisation_secret(scope, %{
                 name: "APPS",
                 values: [%{value_id: "shop", value: "a"}, %{value_id: "docs", value: "b"}]
               })

      assert reveal(organisation, secret, "shop") == {:ok, "a"}
      assert reveal(organisation, secret, "docs") == {:ok, "b"}
    end

    test "the edition's refusal is handed back as it is", %{
      scope: scope,
      organisation: organisation
    } do
      secret = create!(scope, %{name: "API_KEY"})
      %{scope: member} = member_fixture(scope)

      assert {:ok, [%Secret{name: "API_KEY"}]} = Secrets.list_organisation_secrets(member)

      assert Secrets.create_organisation_secret(member, %{name: "MINE", value: "x"}) ==
               {:error, :forbidden}

      assert Secrets.update_secret(member, secret, %{name: "RENAMED"}) == {:error, :forbidden}
      assert Secrets.set_value(member, secret, nil, "x") == {:error, :forbidden}

      assert Secrets.add_value(member, secret, %{value_id: "a", value: "x", first_value_id: "b"}) ==
               {:error, :forbidden}

      assert Secrets.rename_value(member, secret, nil, "a") == {:error, :forbidden}
      assert Secrets.delete_value(member, secret, nil) == {:error, :forbidden}
      assert Secrets.delete_secret(member, secret) == {:error, :forbidden}

      # A person removed is asked of as they are now, not as their scope was loaded.
      %{scope: gone, membership: membership} = member_fixture(scope, :admin)
      {:ok, _} = Apiary.Organisations.remove_member(scope, membership.id)
      assert Secrets.list_organisation_secrets(gone) == {:error, :not_found}

      assert Secrets.create_organisation_secret(gone, %{name: "MINE", value: "x"}) ==
               {:error, :not_found}

      assert Secrets.delete_secret(gone, secret) == {:error, :not_found}
      assert reveal(organisation, secret) == {:ok, @value}
    end

    test "an admin changes them", %{scope: scope} do
      %{scope: admin} = member_fixture(scope, :admin)

      assert {:ok, secret} =
               Secrets.create_organisation_secret(admin, %{name: "API_KEY", value: "x"})

      assert {:ok, _} = Secrets.delete_secret(admin, secret)
    end

    test "another organisation's secrets are out of reach", %{
      scope: scope,
      organisation: organisation
    } do
      theirs = create!(scope, %{name: "THEIRS"})
      %{scope: other, organisation: other_organisation} = sign_up_fixture()

      assert Secrets.list_organisation_secrets(other) == {:ok, []}
      assert Secrets.get_organisation_secret(other, theirs.public_id) == {:error, :not_found}
      assert Secrets.update_secret(other, theirs, %{name: "MINE"}) == {:error, :not_found}
      assert Secrets.set_value(other, theirs, nil, "x") == {:error, :not_found}
      assert Secrets.delete_secret(other, theirs) == {:error, :not_found}
      assert Secrets.list_uses(other, [theirs]) == {:ok, %{theirs.id => []}}
      assert reveal(other_organisation, theirs) == {:error, :not_found}
      assert reveal(organisation, theirs) == {:ok, @value}
    end

    test "an organisation has one data key, made with its first secret, and no workspace's",
         %{scope: scope, organisation: organisation, workspace: workspace} do
      assert organisation_keys(organisation) == []

      one = create!(scope, %{name: "ONE"})
      two = create!(scope, %{name: "TWO", value_id: "main-app"})

      assert [%OrganisationDataKey{id: key_id}] = organisation_keys(organisation)

      for {secret, value_id} <- [{one, nil}, {two, "main-app"}] do
        row = row!(secret, value_id)
        assert row.organisation_data_key_id == key_id
        assert row.data_key_id == nil
        assert row.workspace_id == nil
      end

      assert Repo.aggregate(from(k in DataKey, where: k.workspace_id == ^workspace.id), :count) ==
               0

      # A workspace's secret makes the workspace's key, and takes nothing of the
      # organisation's.
      mine = create_in_workspace!(scope, %{name: "MINE"})
      assert row!(mine, nil).organisation_data_key_id == nil
      assert row!(mine, nil).data_key_id
      assert [%OrganisationDataKey{id: ^key_id}] = organisation_keys(organisation)
    end

    test "the value is the documented AES-256-GCM over the documented v2 associated data",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY", value_id: "main"})
      row = row!(secret, "main")
      data_key = Repo.get!(OrganisationDataKey, row.organisation_data_key_id)

      {key_id, values_key} = KeyDerivation.key(:values)
      assert data_key.wrapping_key_id == key_id
      assert byte_size(data_key.wrapped_key) == 60

      data_key_aad = <<18::16, "apiary-data-key-v2", 36::16, organisation.id::binary>>
      <<wrap_nonce::binary-12, wrapped::binary-32, wrap_tag::binary-16>> = data_key.wrapped_key

      key =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          values_key,
          wrap_nonce,
          wrapped,
          data_key_aad,
          wrap_tag,
          false
        )

      assert byte_size(key) == 32

      aad =
        <<14::16, "qory-secret-v2", 36::16, organisation.id::binary, 20::16,
          secret.public_id::binary, 4::16, "main">>

      size = byte_size(row.ciphertext) - 16
      <<body::binary-size(^size), tag::binary-16>> = row.ciphertext

      assert :crypto.crypto_one_time_aead(:aes_256_gcm, key, row.nonce, body, aad, tag, false) ==
               @value
    end

    test "a value copied to the other level, another secret or another organisation does not decrypt",
         %{scope: scope, organisation: organisation} do
      ours = create!(scope, %{name: "OURS"})
      other = create!(scope, %{name: "OTHER"})
      in_workspace = create_in_workspace!(scope, %{name: "OURS"})
      %{scope: their_scope, organisation: their_organisation} = sign_up_fixture()
      theirs = create!(their_scope, %{name: "THEIRS"})
      a = row!(ours, nil)
      w = row!(in_workspace, nil)

      copy = fn from, to ->
        Repo.query!("UPDATE secret_values SET nonce = $1, ciphertext = $2 WHERE secret_id = $3", [
          from.nonce,
          from.ciphertext,
          dump(to.id)
        ])
      end

      # Another secret of the organisation.
      copy.(a, other)
      capture_log(fn -> assert reveal(organisation, other) == {:error, :unavailable} end)

      # Another organisation's secret, with its data key replaced with ours: its id is in
      # both associated data.
      Repo.query!(
        """
        UPDATE organisation_data_keys
        SET wrapped_key = (SELECT wrapped_key FROM organisation_data_keys WHERE organisation_id = $1)
        WHERE organisation_id = $2
        """,
        [dump(organisation.id), dump(their_organisation.id)]
      )

      capture_log(fn -> assert reveal(their_organisation, theirs) == {:error, :unavailable} end)
      copy.(a, theirs)
      capture_log(fn -> assert reveal(their_organisation, theirs) == {:error, :unavailable} end)

      # The organisation's value in the workspace's secret of the same name, and the
      # workspace's in the organisation's: each level binds its label and its id.
      copy.(a, in_workspace)

      capture_log(fn ->
        assert Secrets.reveal_for_sealing(scope.workspace, in_workspace.public_id, nil) ==
                 {:error, :unavailable}
      end)

      copy.(w, ours)
      capture_log(fn -> assert reveal(organisation, ours) == {:error, :unavailable} end)
    end

    test "a tampered organisation data key unwraps to nothing, and no write goes under another",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY"})

      Repo.query!(
        "UPDATE organisation_data_keys SET wrapped_key = set_byte(wrapped_key, 19, get_byte(wrapped_key, 19) # 255) WHERE organisation_id = $1",
        [dump(organisation.id)]
      )

      log = capture_log(fn -> assert reveal(organisation, secret) == {:error, :unavailable} end)
      assert log =~ "APIARY_ENCRYPTION_SECRET"

      capture_log(fn ->
        assert Secrets.create_organisation_secret(scope, %{name: "OTHER", value: "x"}) ==
                 {:error, :key_unavailable}
      end)
    end

    test "a workspace's reveal never finds an organisation's secret, nor the reverse",
         %{scope: scope, organisation: organisation, workspace: workspace} do
      at_organisation = create!(scope, %{name: "AT_ORGANISATION"})
      at_workspace = create_in_workspace!(scope, %{name: "AT_WORKSPACE"})

      assert Secrets.reveal_for_sealing(workspace, at_organisation.public_id, nil) ==
               {:error, :not_found}

      assert reveal(organisation, at_workspace) == {:error, :not_found}
      assert Secrets.reveal_for_sealing(workspace, at_workspace.public_id, nil) == {:ok, @value}
      assert reveal(organisation, at_organisation) == {:ok, @value}
    end

    test "each level's reads and writes keep to it", %{scope: scope} do
      at_organisation = create!(scope, %{name: "AT_ORGANISATION"})
      at_workspace = create_in_workspace!(scope, %{name: "AT_WORKSPACE"})

      assert {:ok, [%Secret{name: "AT_WORKSPACE"}]} = Secrets.list_secrets(scope)
      assert {:ok, [%Secret{name: "AT_ORGANISATION"}]} = Secrets.list_organisation_secrets(scope)
      assert Secrets.get_secret(scope, at_organisation.public_id) == {:error, :not_found}

      assert Secrets.get_organisation_secret(scope, at_workspace.public_id) ==
               {:error, :not_found}

      # A secret is changed at the level it is read again at, whatever its struct says.
      assert Secrets.update_secret(scope, %{at_workspace | workspace_id: nil}, %{name: "X"}) ==
               {:error, :not_found}

      assert Secrets.update_secret(
               scope,
               %{at_organisation | workspace_id: scope.workspace.id},
               %{name: "X"}
             ) == {:error, :not_found}

      assert {:ok, uses} = Secrets.list_uses(scope, [at_organisation, at_workspace])
      assert uses == %{at_organisation.id => [], at_workspace.id => []}
    end

    test "an organisation's secrets' names are unique among them whatever their case",
         %{scope: scope, owner: owner} do
      create!(scope, %{name: "API_KEY"})

      for name <- ["API_KEY", "api_key"] do
        assert {:error, changeset} =
                 Secrets.create_organisation_secret(scope, %{name: name, value: "x"})

        assert {"is already the name of a secret in this organisation, compared without case", _} =
                 changeset.errors[:name]
      end

      two = create!(scope, %{name: "TWO"})
      assert {:error, changeset} = Secrets.update_secret(scope, two, %{name: "Api_Key"})
      assert changeset.errors[:name]

      # Another organisation's, and a workspace's, take the name all the same.
      assert {:ok, _} =
               Secrets.create_organisation_secret(sign_up_fixture().scope, %{
                 name: "API_KEY",
                 value: "x"
               })

      other = workspace_scope(owner.user, workspace_fixture(owner.organisation))
      create_in_workspace!(scope, %{name: "API_KEY"})
      create_in_workspace!(other, %{name: "API_KEY"})

      # Within a workspace, as before.
      assert {:error, changeset} = Secrets.create_secret(scope, %{name: "api_key", value: "x"})

      assert {"is already the name of a secret in this workspace, compared without case", _} =
               changeset.errors[:name]
    end

    test "a workspace's secret and the organisation's may have the same name", %{scope: scope} do
      at_organisation = create!(scope, %{name: "API_KEY"})
      at_workspace = create_in_workspace!(scope, %{name: "api_key"})
      refute at_organisation.id == at_workspace.id
    end

    test "every change leaves its secret.write entry in the organisation's trail, with its level",
         %{scope: scope, owner: owner, workspace: workspace} do
      secret = create!(scope, %{name: "KEYS"})
      {:ok, secret} = Secrets.update_secret(scope, secret, %{note: "Deploys"})
      {:ok, secret} = Secrets.set_value(scope, secret, nil, "second value")

      {:ok, secret} =
        Secrets.add_value(scope, secret, %{value_id: "bot", value: "bot", first_value_id: "main"})

      {:ok, secret} = Secrets.rename_value(scope, secret, "bot", "robot")
      {:ok, secret} = Secrets.delete_value(scope, secret, "robot")
      {:ok, _} = Secrets.delete_secret(scope, secret)

      entries = trail(secret)

      assert Enum.map(entries, & &1.details["change"]) ==
               ~w(created updated value_set value_added value_renamed value_deleted deleted)

      assert Enum.all?(entries, &(&1.action == "secret.write" and &1.subject_kind == "secret"))
      assert Enum.all?(entries, &(&1.details["level"] == "organisation"))
      assert Enum.all?(entries, &is_nil(&1.workspace_id))

      ids = MapSet.new(entries, & &1.id)

      # Listed by the organisation's audit log, and by no workspace's.
      assert {:ok, %{entries: listed}} = Audit.list_entries(scope, %{action: :"secret.write"})
      assert MapSet.subset?(ids, MapSet.new(listed, & &1.id))

      other = workspace_fixture(owner.organisation)

      for id <- [workspace.id, other.id] do
        assert {:ok, %{entries: in_workspace}} =
                 Audit.list_entries(scope, %{workspace_id: id, action: :"secret.write"})

        assert MapSet.disjoint?(ids, MapSet.new(in_workspace, & &1.id))
      end

      # A workspace's secret's entries keep no level.
      mine = create_in_workspace!(scope, %{name: "MINE"})
      assert [%Entry{details: details, workspace_id: workspace_id}] = trail(mine)
      refute Map.has_key?(details, "level")
      assert workspace_id == workspace.id
    end
  end

  describe "sealing" do
    test "an edition's refusal of :seal stops it, and a workspace's sealing goes on",
         %{scope: scope, organisation: organisation, workspace: workspace} do
      grant()
      secret = create!(scope, %{name: "API_KEY"})
      mine = create_in_workspace!(scope, %{name: "API_KEY"})
      assert reveal(organisation, secret) == {:ok, @value}

      Edition.put_test_stub(EditionStubs.GrantsOrganisationSecretsWithoutSealing)
      assert reveal(organisation, secret) == {:error, :not_found}
      assert {:ok, [_]} = Secrets.list_organisation_secrets(scope)
      assert Secrets.reveal_for_sealing(workspace, mine.public_id, nil) == {:ok, @value}
    end
  end

  describe "the associated data" do
    @organisation_id "0b6f6c1e-8a4e-4b8e-9d55-3f1f3b0c7a10"
    @workspace_id "5d1c2a9e-2f3b-4c8d-a1e7-6b0e9f4d2c31"
    @secret_id "sec_0123456789abcdef"

    test "v1 binds a workspace's value and data key, byte for byte" do
      assert Cipher.value_aad(@workspace_id, @secret_id, "main") ==
               <<0, 14>> <>
                 "qory-secret-v1" <>
                 <<0, 36>> <> @workspace_id <> <<0, 20>> <> @secret_id <> <<0, 4>> <> "main"

      assert Cipher.value_aad(@workspace_id, @secret_id, nil) ==
               <<0, 14>> <>
                 "qory-secret-v1" <>
                 <<0, 36>> <> @workspace_id <> <<0, 20>> <> @secret_id <> <<0, 0>>

      assert Cipher.data_key_aad(@organisation_id, @workspace_id) ==
               <<0, 18>> <>
                 "apiary-data-key-v1" <>
                 <<0, 36>> <> @organisation_id <> <<0, 36>> <> @workspace_id
    end

    test "v2 binds an organisation's value and data key, byte for byte" do
      assert Cipher.organisation_value_aad(@organisation_id, @secret_id, "main") ==
               <<0, 14>> <>
                 "qory-secret-v2" <>
                 <<0, 36>> <> @organisation_id <> <<0, 20>> <> @secret_id <> <<0, 4>> <> "main"

      assert Cipher.organisation_value_aad(@organisation_id, @secret_id, nil) ==
               Cipher.organisation_value_aad(@organisation_id, @secret_id, "")

      assert Cipher.organisation_data_key_aad(@organisation_id) ==
               <<0, 18>> <> "apiary-data-key-v2" <> <<0, 36>> <> @organisation_id
    end

    test "the two levels' associated data never meet" do
      key = Cipher.new_data_key()
      aad = Cipher.organisation_value_aad(@organisation_id, @secret_id, "main")
      {nonce, ciphertext} = Cipher.encrypt(key, aad, "plain")

      assert Cipher.decrypt(key, aad, nonce, ciphertext) == {:ok, "plain"}

      for other <- [
            Cipher.value_aad(@organisation_id, @secret_id, "main"),
            Cipher.organisation_value_aad(Ecto.UUID.generate(), @secret_id, "main"),
            Cipher.organisation_value_aad(@organisation_id, "sec_0123456789abcdeg", "main"),
            Cipher.organisation_value_aad(@organisation_id, @secret_id, nil)
          ] do
        assert Cipher.decrypt(key, other, nonce, ciphertext) == :error
      end

      refute Cipher.organisation_data_key_aad(@organisation_id) ==
               Cipher.data_key_aad(@organisation_id, @workspace_id)
    end
  end

  describe "the database" do
    setup do
      grant()
    end

    test "refuses a value at another level than its secret's",
         %{scope: scope, organisation: organisation, workspace: workspace} do
      at_organisation = create!(scope, %{name: "AT_ORGANISATION"})
      at_workspace = create_in_workspace!(scope, %{name: "AT_WORKSPACE"})
      o = row!(at_organisation, nil)
      w = row!(at_workspace, nil)

      # A value without a workspace, of a secret with one: the trigger.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO secret_values
              (id, organisation_id, workspace_id, secret_id, value_id, organisation_data_key_id,
               nonce, ciphertext, inserted_at, updated_at)
            VALUES ($1, $2, NULL, $3, 'moved', $4, $5, $6, now(), now())
            """,
            [
              dump(Ecto.UUID.generate()),
              dump(organisation.id),
              dump(at_workspace.id),
              dump(o.organisation_data_key_id),
              o.nonce,
              o.ciphertext
            ]
          )
        end

      assert error.postgres.constraint == "secret_value_scope_matches"

      # The organisation's value moved to the workspace's secret: the same.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE secret_values SET secret_id = $1 WHERE id = $2", [
            dump(at_workspace.id),
            dump(o.id)
          ])
        end

      assert error.postgres.constraint == "secret_value_scope_matches"

      # A value with a workspace, of a secret without one: its key to its secret.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE secret_values SET secret_id = $1, value_id = 'moved' WHERE id = $2",
            [
              dump(at_organisation.id),
              dump(w.id)
            ]
          )
        end

      assert error.postgres.constraint == "secret_values_secret_id_fkey"

      # A secret without a workspace that gets one while it has values.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE secrets SET workspace_id = $1 WHERE id = $2", [
            dump(workspace.id),
            dump(at_organisation.id)
          ])
        end

      assert error.postgres.constraint == "secret_value_scope_matches"

      # A secret of a workspace that loses it while it has values: the same.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE secrets SET workspace_id = NULL WHERE id = $1", [
            dump(at_workspace.id)
          ])
        end

      assert error.postgres.constraint == "secret_value_scope_matches"
    end

    test "a value has exactly one data key, of its level", %{scope: scope, workspace: workspace} do
      at_organisation = create!(scope, %{name: "AT_ORGANISATION"})
      at_workspace = create_in_workspace!(scope, %{name: "AT_WORKSPACE"})
      o = row!(at_organisation, nil)
      w = row!(at_workspace, nil)

      for {sql, params} <- [
            {"UPDATE secret_values SET data_key_id = $1 WHERE id = $2",
             [dump(w.data_key_id), dump(o.id)]},
            {"UPDATE secret_values SET organisation_data_key_id = $1 WHERE id = $2",
             [dump(o.organisation_data_key_id), dump(w.id)]},
            {"UPDATE secret_values SET organisation_data_key_id = NULL WHERE id = $1",
             [dump(o.id)]}
          ] do
        error = assert_raise Postgrex.Error, fn -> Repo.query!(sql, params) end

        assert error.postgres.constraint in [
                 "secret_values_one_key",
                 "secret_values_data_key_id_fkey"
               ]
      end

      # Both NULL with a workspace: the check alone.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE secret_values SET data_key_id = NULL WHERE id = $1 AND workspace_id = $2",
            [dump(w.id), dump(workspace.id)]
          )
        end

      assert error.postgres.constraint == "secret_values_one_key"
    end

    test "an organisation's deletion takes its secrets and data key with it",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY"})
      Repo.query!("DELETE FROM organisations WHERE id = $1", [dump(organisation.id)])

      assert Repo.get(Secret, secret.id) == nil
      assert organisation_keys(organisation) == []
    end
  end
end

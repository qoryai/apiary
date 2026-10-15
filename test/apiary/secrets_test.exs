defmodule Apiary.SecretsTest do
  use Apiary.DataCase, async: true

  @moduletag needs: :secrets

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{KeyDerivation, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Secrets.{Cipher, DataKey, Secret, Value}

  @value "ghp_exampleTokenValue0123456789"

  setup do
    owner = sign_up_fixture()

    %{
      owner: owner,
      scope: owner.scope,
      workspace: owner.scope.workspace,
      organisation: owner.scope.organisation
    }
  end

  defp create!(scope, attrs) do
    {:ok, secret} = Secrets.create_secret(scope, Map.merge(%{value: @value}, attrs))
    secret
  end

  defp reveal(scope, secret, value_id \\ nil),
    do: Secrets.reveal_for_sealing(scope.organisation, secret.public_id, value_id)

  # A scope of the owner in another workspace of the organisation.
  defp other_workspace(owner),
    do: workspace_scope(owner.user, workspace_fixture(owner.organisation))

  defp row!(secret, value_id) do
    query = from v in Value, where: v.secret_id == ^secret.id

    query =
      if value_id,
        do: where(query, [v], v.value_id == ^value_id),
        else: where(query, [v], is_nil(v.value_id))

    Repo.one!(query)
  end

  defp trail(secret),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^secret.id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  # The data key `row` is encrypted under, unwrapped.
  defp data_key!(row) do
    data_key = Repo.get!(DataKey, row.data_key_id)
    {:ok, values_key} = KeyDerivation.key(:values, data_key.wrapping_key_id)

    {:ok, key} =
      Cipher.unwrap(
        values_key,
        data_key.wrapped_key,
        Cipher.data_key_aad(data_key.organisation_id)
      )

    key
  end

  defp put_value!(row, nonce, ciphertext) do
    Repo.query!("UPDATE secret_values SET nonce = $1, ciphertext = $2 WHERE id = $3", [
      nonce,
      ciphertext,
      Ecto.UUID.dump!(row.id)
    ])
  end

  describe "storing a value" do
    test "a value round-trips, and only reveal_for_sealing/3 gives it back", %{scope: scope} do
      secret = create!(scope, %{name: "GITHUB_TOKEN", note: "Opens pull requests"})

      assert secret.public_id =~ ~r/\Asec_[0-9a-hjkmnp-tv-z]{16}\z/
      assert secret.name == "GITHUB_TOKEN"
      assert secret.note == "Opens pull requests"
      assert [%Value{value_id: nil, value: nil, nonce: nil, ciphertext: nil}] = secret.values

      assert reveal(scope, secret) == {:ok, @value}
    end

    test "the database holds the value only as AES-256-GCM ciphertext under a fresh nonce",
         %{scope: scope} do
      one = create!(scope, %{name: "ONE"})
      two = create!(scope, %{name: "TWO"})
      a = row!(one, nil)
      b = row!(two, nil)

      assert byte_size(a.nonce) == 12
      assert byte_size(a.ciphertext) == byte_size(@value) + 16
      refute a.ciphertext =~ @value
      refute a.nonce == b.nonce
      refute a.ciphertext == b.ciphertext

      # Nothing of the value is in the row as the database returns it.
      %{rows: rows} =
        Repo.query!("SELECT * FROM secret_values WHERE id = $1", [Ecto.UUID.dump!(a.id)])

      refute inspect(rows, limit: :infinity, printable_limit: :infinity) =~ @value
    end

    test "the value is the documented AES-256-GCM over the documented associated data",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY"})
      row = row!(secret, nil)
      data_key = Repo.get!(DataKey, row.data_key_id)
      assert data_key.organisation_id == organisation.id

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
          secret.public_id::binary, 0::16>>

      size = byte_size(row.ciphertext) - 16
      <<body::binary-size(^size), tag::binary-16>> = row.ciphertext

      assert :crypto.crypto_one_time_aead(:aes_256_gcm, key, row.nonce, body, aad, tag, false) ==
               @value
    end

    test "an organisation has one data key, made with its first secret, for every workspace",
         %{owner: owner, scope: scope, organisation: organisation} do
      keys = fn ->
        Repo.aggregate(from(k in DataKey, where: k.organisation_id == ^organisation.id), :count)
      end

      assert keys.() == 0

      one = create!(scope, %{name: "ONE"})
      two = create!(scope, %{name: "TWO", value_id: "main-app"})
      three = create!(other_workspace(owner), %{name: "THREE"})

      assert keys.() == 1

      rows = [row!(one, nil), row!(two, "main-app"), row!(three, nil)]
      assert rows |> Enum.map(& &1.data_key_id) |> Enum.uniq() |> length() == 1
    end

    test "inspect, JSON and the changeset never show a value", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})
      row = row!(secret, nil)

      refute inspect(secret, limit: :infinity) =~ @value
      refute inspect(row, limit: :infinity) =~ Base.encode16(row.ciphertext)
      # Redacted fields are left out of the struct's inspect altogether.
      refute inspect(row, limit: :infinity) =~ "ciphertext"
      refute inspect(row, limit: :infinity) =~ "nonce"

      json = Jason.encode!(%{secret | values: [row]})
      refute json =~ "ciphertext"
      refute json =~ "nonce"
      assert json =~ secret.public_id

      changeset = Value.changeset(%Value{}, %{"value" => @value})
      refute inspect(changeset, limit: :infinity) =~ @value

      {:error, refused} = Secrets.create_secret(scope, %{name: "bad name", value: @value})
      refute inspect(refused, limit: :infinity) =~ @value
    end

    test "a value is UTF-8 text of 1 to 16384 bytes without NUL, and an error never repeats it",
         %{scope: scope} do
      assert {:ok, _} =
               Secrets.create_secret(scope, %{
                 name: "LONGEST",
                 value: String.duplicate("a", 16_384)
               })

      for {value, message} <- [
            {String.duplicate("a", 16_385), "must be at most %{count} bytes"},
            {"", "can't be blank"},
            {nil, "can't be blank"},
            {"before" <> <<0>> <> "after", "must not contain a NUL byte"},
            {<<0xFF, 0xFE>>, "must be UTF-8 text"}
          ] do
        assert {:error, changeset} = Secrets.create_secret(scope, %{name: "BAD", value: value})
        assert {^message, _} = changeset.errors[:value]
      end

      # A PEM key keeps its line breaks.
      pem = "-----BEGIN EXAMPLE-----\nAAAA\n-----END EXAMPLE-----\n"
      assert {:ok, secret} = Secrets.create_secret(scope, %{name: "PEM_KEY", value: pem})
      assert reveal(scope, secret) == {:ok, pem}
    end
  end

  describe "names and notes" do
    test "a name keeps a variable's rule", %{scope: scope} do
      for name <- ["API_KEY", "_PRIVATE", "a", "Mixed_Case_9", String.duplicate("A", 128)] do
        assert {:ok, _} = Secrets.create_secret(scope, %{name: name, value: @value})
      end

      for name <- ["", "9LIVES", "API-KEY", "API KEY", "ÄPI", String.duplicate("A", 129)] do
        assert {:error, changeset} = Secrets.create_secret(scope, %{name: name, value: @value}),
               "#{inspect(name)} was taken"

        assert changeset.errors[:name]
      end
    end

    test "names are unique in the organisation whatever their case, in every workspace",
         %{scope: scope, owner: owner} do
      create!(scope, %{name: "GITHUB_APP_PRIVATE_KEY"})

      for name <- ["GITHUB_APP_PRIVATE_KEY", "github_app_private_key", "GitHub_App_Private_Key"] do
        assert {:error, changeset} = Secrets.create_secret(scope, %{name: name, value: @value})
        assert {message, _} = changeset.errors[:name]
        assert message =~ "compared without case"
      end

      # Another workspace of the organisation has the same names.
      assert {:error, changeset} =
               Secrets.create_secret(other_workspace(owner), %{
                 name: "github_app_private_key",
                 value: @value
               })

      assert changeset.errors[:name]

      # Another organisation may take the name.
      assert {:ok, _} =
               Secrets.create_secret(sign_up_fixture().scope, %{
                 name: "github_app_private_key",
                 value: @value
               })
    end

    test "renaming to another secret's name, in any case, is refused", %{scope: scope} do
      create!(scope, %{name: "ONE"})
      two = create!(scope, %{name: "TWO"})
      assert {:error, changeset} = Secrets.update_secret(scope, two, %{name: "one"})
      assert changeset.errors[:name]
      # Its own name in another case is its to take.
      assert {:ok, %Secret{name: "two"}} = Secrets.update_secret(scope, two, %{name: "two"})
    end

    test "a note's 500 characters are counted as the database counts them", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})
      precomposed = "\u00e9"
      decomposed = "e\u0301"

      assert {:ok, %{note: note}} =
               Secrets.update_secret(scope, secret, %{note: String.duplicate(precomposed, 500)})

      assert String.length(note) == 500

      for note <- [String.duplicate(precomposed, 501), String.duplicate(decomposed, 500)] do
        assert {:error, changeset} = Secrets.update_secret(scope, secret, %{note: note})
        assert changeset.errors[:note]
      end
    end

    test "a note is optional, one line, at most 500 characters", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY", note: "  "})
      assert secret.note == nil

      assert {:ok, %{note: note}} =
               Secrets.update_secret(scope, secret, %{note: String.duplicate("é", 500)})

      assert String.length(note) == 500

      assert {:error, changeset} =
               Secrets.update_secret(scope, secret, %{note: String.duplicate("a", 501)})

      assert changeset.errors[:note]
      assert {:error, changeset} = Secrets.update_secret(scope, secret, %{note: "two\nlines"})
      assert changeset.errors[:note]
    end
  end

  describe "several values" do
    test "a second value names the first, which is encrypted again under its value id",
         %{scope: scope} do
      secret = create!(scope, %{name: "GITHUB_APP_PRIVATE_KEY"})
      before = row!(secret, nil)

      assert {:error, changeset} =
               Secrets.add_value(scope, secret, %{value_id: "bot-app", value: "bot value"})

      assert changeset.errors[:first_value_id]

      assert {:error, changeset} =
               Secrets.add_value(scope, secret, %{
                 value_id: "bot-app",
                 value: "bot value",
                 first_value_id: "bot-app"
               })

      assert changeset.errors[:value_id]

      assert {:ok, secret} =
               Secrets.add_value(scope, secret, %{
                 value_id: "bot-app",
                 value: "bot value",
                 first_value_id: "main-app"
               })

      assert Enum.map(secret.values, & &1.value_id) == ["bot-app", "main-app"]
      assert reveal(scope, secret, "main-app") == {:ok, @value}
      assert reveal(scope, secret, "bot-app") == {:ok, "bot value"}
      assert reveal(scope, secret, nil) == {:error, :not_found}

      renamed = row!(secret, "main-app")
      assert renamed.id == before.id
      refute renamed.nonce == before.nonce

      # A third needs no first value id: every value has one.
      assert {:ok, secret} =
               Secrets.add_value(scope, secret, %{value_id: "ci", value: "ci value"})

      assert length(secret.values) == 3
    end

    test "a value id is a lowercase slug, unique in the secret", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})

      for value_id <- ["Main", "-main", "main app", "main/app", String.duplicate("a", 65), ""] do
        assert {:error, changeset} =
                 Secrets.add_value(scope, secret, %{value_id: value_id, value: "x"}),
               "#{inspect(value_id)} was taken"

        assert changeset.errors[:value_id]
      end

      assert {:error, changeset} =
               Secrets.add_value(scope, secret, %{value_id: "main", value: "x"})

      assert {"is already a value ID of this secret", _} = changeset.errors[:value_id]

      for value_id <- ["0", "a.b", "a_b", "a-b", String.duplicate("a", 64)] do
        assert {:ok, _} = Secrets.add_value(scope, secret, %{value_id: value_id, value: "x"})
      end
    end

    test "a secret has at most #{32} values", %{scope: scope} do
      secret = create!(scope, %{name: "MANY", value_id: "v0"})

      secret =
        Enum.reduce(1..31, secret, fn i, secret ->
          {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "v#{i}", value: "x"})
          secret
        end)

      assert length(secret.values) == Secrets.max_values()

      assert Secrets.add_value(scope, secret, %{value_id: "v32", value: "x"}) ==
               {:error, :too_many_values}
    end

    test "create_secret/2 stores several values at once, each under its value id",
         %{scope: scope} do
      assert {:ok, secret} =
               Secrets.create_secret(scope, %{
                 name: "GITHUB_APP_PRIVATE_KEY",
                 note: "One per app",
                 # As a form sends them: by index, taken in its order, not the map's.
                 values: %{
                   "10" => %{"value_id" => "ci", "value" => "ci value"},
                   "2" => %{"value_id" => " bot-app ", "value" => "bot value"},
                   "0" => %{"value_id" => "main-app", "value" => @value}
                 },
                 # Beside several values, the fields of one value are not looked at.
                 value: "not stored",
                 value_id: "not-stored"
               })

      assert Enum.map(secret.values, & &1.value_id) == ["bot-app", "ci", "main-app"]
      assert reveal(scope, secret, "main-app") == {:ok, @value}
      assert reveal(scope, secret, "bot-app") == {:ok, "bot value"}
      assert reveal(scope, secret, "ci") == {:ok, "ci value"}
      assert reveal(scope, secret, "not-stored") == {:error, :not_found}
      assert reveal(scope, secret, nil) == {:error, :not_found}

      # One entry, the value ids in the order they came, never a value.
      assert [created] = trail(secret)
      assert created.details["change"] == "created"
      assert created.after["value_ids"] == ["main-app", "bot-app", "ci"]
      kept = Jason.encode!([created.before, created.after, created.details])
      for value <- [@value, "bot value", "ci value"], do: refute(kept =~ value)

      # A list is taken as it is.
      assert {:ok, secret} =
               Secrets.create_secret(scope, %{
                 name: "DEPLOY_KEYS",
                 values: [%{value_id: "shop", value: "a"}, %{value_id: "docs", value: "b"}]
               })

      assert Enum.map(secret.values, & &1.value_id) == ["docs", "shop"]
    end

    test "create_secret/2 refuses several values with any of them wrong, storing none",
         %{scope: scope} do
      value = "plaintext-that-must-not-stay"

      assert {:error, changeset} =
               Secrets.create_secret(scope, %{
                 name: "1BAD",
                 values: %{
                   "0" => %{"value_id" => "main-app", "value" => value},
                   "1" => %{"value_id" => "main-app", "value" => value},
                   "2" => %{"value_id" => "Main", "value" => ""},
                   "3" => %{"value_id" => "", "value" => value}
                 }
               })

      assert changeset.errors[:name]

      assert [first, duplicate, wrong, unnamed] = changeset.changes.values
      assert first.errors == []
      assert {"is already a value ID of this secret", _} = duplicate.errors[:value_id]
      assert wrong.errors[:value_id]
      assert {"can't be blank", _} = wrong.errors[:value]
      assert {"can't be blank", _} = unnamed.errors[:value_id]
      refute unnamed.errors[:value]

      # Neither the secret's changeset nor a value's under it keeps a value.
      refute Map.has_key?(changeset.params, "values")
      refute inspect(changeset, limit: :infinity, structs: false) =~ value

      for child <- changeset.changes.values do
        refute Map.has_key?(child.params, "value")
        refute Map.has_key?(child.changes, :value)
      end

      # A value id that is another's once trimmed is the same value id.
      assert {:error, changeset} =
               Secrets.create_secret(scope, %{
                 name: "KEYS",
                 values: %{
                   "0" => %{"value_id" => "main", "value" => "a"},
                   "1" => %{"value_id" => " main ", "value" => "b"}
                 }
               })

      assert [_main, again] = changeset.changes.values
      assert {"is already a value ID of this secret", _} = again.errors[:value_id]

      # None, and more than the most a secret holds.
      assert {:error, changeset} = Secrets.create_secret(scope, %{name: "NONE", values: %{}})
      assert {"can't be blank", _} = changeset.errors[:values]

      many = Map.new(0..32, &{to_string(&1), %{"value_id" => "v#{&1}", "value" => "x"}})
      assert {:error, changeset} = Secrets.create_secret(scope, %{name: "MANY", values: many})
      assert {"A secret holds at most %{count} values.", opts} = changeset.errors[:values]
      assert opts[:count] == 32
      # Refused on their count, before any of them is looked at: none is under it.
      refute Map.has_key?(changeset.changes, :values)
      refute Map.has_key?(changeset.params, "values")

      # Counted as they were sent, whatever they hold.
      junk = Map.new(0..32, &{"key-#{&1}", "not a value"})
      assert {:error, changeset} = Secrets.create_secret(scope, %{name: "MANY", values: junk})
      assert {"A secret holds at most %{count} values.", _} = changeset.errors[:values]

      # A value ID or a value that is not text is an error on its own row.
      assert {:error, changeset} =
               Secrets.create_secret(scope, %{
                 name: "SHAPES",
                 values: %{
                   "0" => %{"value_id" => %{"a" => "b"}, "value" => "x"},
                   "1" => %{"value_id" => "docs", "value" => %{"a" => "b"}},
                   "2" => %{"value_id" => ["shop"], "value" => 7}
                 }
               })

      assert [map_id, map_value, other] = changeset.changes.values
      assert {"is invalid", _} = map_id.errors[:value_id]
      refute map_id.errors[:value]
      assert map_value.errors[:value]
      refute map_value.errors[:value_id]
      assert other.errors[:value_id] && other.errors[:value]

      assert Secrets.list_secrets(scope) == {:ok, []}

      # The most a secret holds is stored.
      assert {:ok, secret} =
               Secrets.create_secret(scope, %{name: "MANY", values: Map.delete(many, "32")})

      assert length(secret.values) == Secrets.max_values()
    end

    test "set_value/4 replaces a value, under a new nonce", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})
      before = row!(secret, nil)

      assert {:ok, _} = Secrets.set_value(scope, secret, nil, "rotated value")
      assert reveal(scope, secret) == {:ok, "rotated value"}
      refute row!(secret, nil).nonce == before.nonce

      assert Secrets.set_value(scope, secret, "nope", "x") == {:error, :not_found}
      assert {:error, changeset} = Secrets.set_value(scope, secret, nil, "")
      assert changeset.errors[:value]
      assert reveal(scope, secret) == {:ok, "rotated value"}
    end

    test "rename_value/4 encrypts the value again under its new id", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})
      assert {:ok, secret} = Secrets.rename_value(scope, secret, "main", "primary")
      assert reveal(scope, secret, "primary") == {:ok, @value}
      assert reveal(scope, secret, "main") == {:error, :not_found}

      assert Secrets.rename_value(scope, secret, "main", "other") == {:error, :not_found}
      assert {:error, changeset} = Secrets.rename_value(scope, secret, "primary", "Not A Slug")
      assert changeset.errors[:value_id]
    end

    test "a new value id is stored as given, trimmed, and bound as stored", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})

      # A blank around the same id is no rename, and leaves no entry.
      assert {:ok, _} = Secrets.rename_value(scope, secret, "main", " main ")
      assert length(trail(secret)) == 1

      assert {:ok, secret} = Secrets.rename_value(scope, secret, "main", " primary ")
      assert Enum.map(secret.values, & &1.value_id) == ["primary"]
      assert reveal(scope, secret, "primary") == {:ok, @value}
      assert List.last(trail(secret)).after == %{"value_id" => "primary"}

      assert {:error, changeset} = Secrets.rename_value(scope, secret, "primary", "   ")
      assert changeset.errors[:value_id]
      assert reveal(scope, secret, "primary") == {:ok, @value}
    end

    test "delete_value/3 deletes a value, never the last", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})
      assert Secrets.delete_value(scope, secret, "main") == {:error, :last_value}

      {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "bot", value: "bot value"})
      assert {:ok, secret} = Secrets.delete_value(scope, secret, "main")
      assert Enum.map(secret.values, & &1.value_id) == ["bot"]
      assert reveal(scope, secret, "main") == {:error, :not_found}
      assert Secrets.delete_value(scope, secret, "main") == {:error, :not_found}
    end

    test "delete_secret/2 deletes a secret with its values", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})
      {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "bot", value: "bot value"})

      assert {:ok, %Secret{}} = Secrets.delete_secret(scope, secret)
      assert Secrets.get_secret(scope, secret.public_id) == {:error, :not_found}
      assert Repo.aggregate(from(v in Value, where: v.secret_id == ^secret.id), :count) == 0
      assert reveal(scope, secret, "bot") == {:error, :not_found}
    end
  end

  describe "the associated data binds a value to where it belongs" do
    test "a value moved to another secret does not decrypt there", %{scope: scope} do
      one = create!(scope, %{name: "ONE"})
      two = create!(scope, %{name: "TWO"})
      a = row!(one, nil)

      # Two's ciphertext replaced with one's: the same data key, another secret id.
      Repo.query!("UPDATE secret_values SET nonce = $1, ciphertext = $2 WHERE secret_id = $3", [
        a.nonce,
        a.ciphertext,
        Ecto.UUID.dump!(two.id)
      ])

      log = capture_log(fn -> assert reveal(scope, two) == {:error, :unavailable} end)
      assert log =~ "secret_id=#{two.public_id}"
      refute log =~ @value

      # The row itself moved to the other secret: the same.
      Repo.query!("DELETE FROM secret_values WHERE secret_id = $1", [Ecto.UUID.dump!(two.id)])

      Repo.query!("UPDATE secret_values SET secret_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(two.id),
        Ecto.UUID.dump!(a.id)
      ])

      capture_log(fn -> assert reveal(scope, two) == {:error, :unavailable} end)
    end

    test "a value moved to another value id does not decrypt there", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", value_id: "main"})
      {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "bot", value: "bot value"})
      main = row!(secret, "main")
      bot = row!(secret, "bot")

      Repo.query!("UPDATE secret_values SET value_id = 'swap' WHERE id = $1", [
        Ecto.UUID.dump!(main.id)
      ])

      Repo.query!("UPDATE secret_values SET value_id = 'main' WHERE id = $1", [
        Ecto.UUID.dump!(bot.id)
      ])

      Repo.query!("UPDATE secret_values SET value_id = 'bot' WHERE id = $1", [
        Ecto.UUID.dump!(main.id)
      ])

      capture_log(fn ->
        assert reveal(scope, secret, "main") == {:error, :unavailable}
        assert reveal(scope, secret, "bot") == {:error, :unavailable}
      end)
    end

    test "a value moved to another organisation does not decrypt there", %{scope: scope} do
      other_scope = sign_up_fixture().scope
      mine = create!(scope, %{name: "API_KEY"})
      theirs = create!(other_scope, %{name: "API_KEY"})
      a = row!(mine, nil)
      theirs_key = Repo.get_by!(DataKey, organisation_id: other_scope.organisation.id)

      # Their data key replaced with mine: the other organisation's id is in the data
      # key's associated data, so it does not unwrap there.
      Repo.query!(
        """
        UPDATE organisation_data_keys
        SET wrapped_key = (SELECT wrapped_key FROM organisation_data_keys WHERE organisation_id = $1)
        WHERE organisation_id = $2
        """,
        [Ecto.UUID.dump!(scope.organisation.id), Ecto.UUID.dump!(other_scope.organisation.id)]
      )

      log = capture_log(fn -> assert reveal(other_scope, theirs) == {:error, :unavailable} end)
      assert log =~ "cannot be unwrapped"

      # Their data key back, and their value replaced with mine: the key unwraps, and the
      # organisation's id in the value's associated data is what refuses it.
      Repo.query!("UPDATE organisation_data_keys SET wrapped_key = $1 WHERE id = $2", [
        theirs_key.wrapped_key,
        Ecto.UUID.dump!(theirs_key.id)
      ])

      assert reveal(other_scope, theirs) == {:ok, @value}

      Repo.query!("UPDATE secret_values SET nonce = $1, ciphertext = $2 WHERE secret_id = $3", [
        a.nonce,
        a.ciphertext,
        Ecto.UUID.dump!(theirs.id)
      ])

      log = capture_log(fn -> assert reveal(other_scope, theirs) == {:error, :unavailable} end)
      assert log =~ "cannot be decrypted"
      refute log =~ "cannot be unwrapped"
      # Mine still reads.
      assert reveal(scope, mine) == {:ok, @value}
    end

    test "a value under the same data key and secret id, bound to another organisation, does not decrypt",
         %{scope: scope, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY"})
      row = row!(secret, nil)
      key = data_key!(row)

      # The value as another organisation's row with the same secret id would bind it.
      aad = Cipher.value_aad(Ecto.UUID.generate(), secret.public_id, nil)
      {nonce, ciphertext} = Cipher.encrypt(key, aad, @value)
      put_value!(row, nonce, ciphertext)
      capture_log(fn -> assert reveal(scope, secret) == {:error, :unavailable} end)

      # Bound to this one, it reads.
      aad = Cipher.value_aad(organisation.id, secret.public_id, nil)
      {nonce, ciphertext} = Cipher.encrypt(key, aad, @value)
      put_value!(row, nonce, ciphertext)
      assert reveal(scope, secret) == {:ok, @value}
    end

    test "a value or a data key bound the first way, by the workspace, does not decrypt",
         %{scope: scope, workspace: workspace, organisation: organisation} do
      secret = create!(scope, %{name: "API_KEY"})
      row = row!(secret, nil)
      key = data_key!(row)

      v1_value_aad =
        <<14::16, "qory-secret-v1", 36::16, workspace.id::binary, 20::16,
          secret.public_id::binary, 0::16>>

      {nonce, ciphertext} = Cipher.encrypt(key, v1_value_aad, @value)
      put_value!(row, nonce, ciphertext)

      log = capture_log(fn -> assert reveal(scope, secret) == {:error, :unavailable} end)
      assert log =~ "cannot be decrypted"
      assert log =~ "secret_id=#{secret.public_id}"
      refute log =~ "cannot be unwrapped"

      # A value bound the current way again, and the same key wrapped the first way: the
      # key does not unwrap.
      aad = Cipher.value_aad(organisation.id, secret.public_id, nil)
      {nonce, ciphertext} = Cipher.encrypt(key, aad, @value)
      put_value!(row, nonce, ciphertext)
      assert reveal(scope, secret) == {:ok, @value}

      {_key_id, values_key} = KeyDerivation.key(:values)

      v1_data_key_aad =
        <<18::16, "apiary-data-key-v1", 36::16, organisation.id::binary, 36::16,
          workspace.id::binary>>

      Repo.query!("UPDATE organisation_data_keys SET wrapped_key = $1 WHERE id = $2", [
        Cipher.wrap(values_key, key, v1_data_key_aad),
        Ecto.UUID.dump!(row.data_key_id)
      ])

      log = capture_log(fn -> assert reveal(scope, secret) == {:error, :unavailable} end)
      assert log =~ "cannot be unwrapped"
      refute log =~ "cannot be decrypted"
    end

    test "the associated data is each part, length-prefixed", %{organisation: organisation} do
      key = Cipher.new_data_key()
      aad = Cipher.value_aad(organisation.id, "sec_0123456789abcdef", "main")
      {nonce, ciphertext} = Cipher.encrypt(key, aad, "plain")

      assert Cipher.decrypt(key, aad, nonce, ciphertext) == {:ok, "plain"}

      for other <- [
            Cipher.value_aad(Ecto.UUID.generate(), "sec_0123456789abcdef", "main"),
            Cipher.value_aad(organisation.id, "sec_0123456789abcdeg", "main"),
            Cipher.value_aad(organisation.id, "sec_0123456789abcdef", nil),
            Cipher.value_aad(organisation.id, "sec_0123456789abcdef", "main2")
          ] do
        assert Cipher.decrypt(key, other, nonce, ciphertext) == :error
      end

      # A value id with no value id is "", not absent: lp("") is two zero bytes.
      assert Cipher.value_aad(organisation.id, "sec_0123456789abcdef", nil) ==
               Cipher.value_aad(organisation.id, "sec_0123456789abcdef", "")

      assert Cipher.decrypt(Cipher.new_data_key(), aad, nonce, ciphertext) == :error
      <<first, rest::binary>> = ciphertext
      assert Cipher.decrypt(key, aad, nonce, <<Bitwise.bxor(first, 1), rest::binary>>) == :error
      assert Cipher.decrypt(key, aad, nonce, "short") == :error
    end

    # Known answers, from fixed inputs: an organisation id, a secret id, a value id, a data
    # key, a values key and the two nonces. The associated data, a value's ciphertext and
    # tag, and a wrapped data key, each as the scheme of `Apiary.Secrets.Cipher` makes it.
    @organisation_id "11111111-2222-4333-8444-555555555555"
    @secret_id "sec_0123456789abcdef"
    @data_key :binary.list_to_bin(Enum.to_list(0..31))
    @values_key :binary.list_to_bin(Enum.to_list(32..63))
    @value_nonce :binary.list_to_bin(Enum.to_list(64..75))
    @wrap_nonce :binary.list_to_bin(Enum.to_list(80..91))

    @value_aad "000e716f72792d7365637265742d7632002431313131313131312d323232322d343333332d383434342d35353535353535353535353500147365635f3031323334353637383961626364656600086d61696e2d617070"
    @data_key_aad "00126170696172792d646174612d6b65792d7632002431313131313131312d323232322d343333332d383434342d353535353535353535353535"
    @ciphertext "85d1de7c4344e66ebda87262f40f76352fa73e29d2053e1144737bd3a02bd4ca2b8a16716d37db5932810dfb922996"
    @wrapped "505152535455565758595a5bb1a1aa11352a710a3c06001161048da0ccfd5d2c6ce36f17bae5c241ac173e26c9581a4baa94a9ce88baabf2300bd831"

    test "the pinned vectors" do
      hex = &Base.decode16!(&1, case: :lower)
      value_aad = Cipher.value_aad(@organisation_id, @secret_id, "main-app")
      data_key_aad = Cipher.data_key_aad(@organisation_id)

      assert value_aad == hex.(@value_aad)
      assert data_key_aad == hex.(@data_key_aad)

      {body, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          @data_key,
          @value_nonce,
          @value,
          value_aad,
          16,
          true
        )

      assert body <> tag == hex.(@ciphertext)

      assert Cipher.decrypt(@data_key, value_aad, @value_nonce, hex.(@ciphertext)) ==
               {:ok, @value}

      {body, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          @values_key,
          @wrap_nonce,
          @data_key,
          data_key_aad,
          16,
          true
        )

      assert @wrap_nonce <> body <> tag == hex.(@wrapped)
      assert Cipher.unwrap(@values_key, hex.(@wrapped), data_key_aad) == {:ok, @data_key}
    end

    test "a tampered wrapped data key unwraps to nothing", %{
      scope: scope,
      organisation: organisation
    } do
      secret = create!(scope, %{name: "API_KEY"})

      Repo.query!(
        "UPDATE organisation_data_keys SET wrapped_key = set_byte(wrapped_key, 19, get_byte(wrapped_key, 19) # 255) WHERE organisation_id = $1",
        [Ecto.UUID.dump!(organisation.id)]
      )

      log = capture_log(fn -> assert reveal(scope, secret) == {:error, :unavailable} end)
      assert log =~ "APIARY_ENCRYPTION_SECRET"

      # A write that needs the key is refused rather than made under another one.
      capture_log(fn ->
        assert Secrets.create_secret(scope, %{name: "OTHER", value: "x"}) ==
                 {:error, :key_unavailable}
      end)
    end
  end

  describe "no changeset handed back keeps a value" do
    defp refute_value(changeset, value) do
      refute Map.has_key?(changeset.params || %{}, "value")
      refute Map.has_key?(changeset.params || %{}, :value)
      refute Map.has_key?(changeset.changes, :value)
      refute inspect(changeset, limit: :infinity, structs: false) =~ value
    end

    test "not on a refused create, a refused set, nor a refused insert", %{scope: scope} do
      value = "plaintext-that-must-not-stay"

      for attrs <- [%{name: "bad name", value: value}, %{"name" => "bad name", "value" => value}] do
        assert {:error, changeset} = Secrets.create_secret(scope, attrs)
        refute_value(changeset, value)
      end

      # Refused by the database: a name already taken.
      secret = create!(scope, %{name: "TAKEN", value_id: "main"})
      assert {:error, changeset} = Secrets.create_secret(scope, %{name: "taken", value: value})
      assert changeset.errors[:name]
      refute_value(changeset, value)

      assert {:error, changeset} = Secrets.set_value(scope, secret, "main", value <> <<0>>)
      refute_value(changeset, value)

      # Refused by the database: a value id the secret has.
      assert {:error, changeset} =
               Secrets.add_value(scope, secret, %{value_id: "main", value: value})

      assert changeset.errors[:value_id]
      refute_value(changeset, value)

      changeset = Secrets.change_secret(secret, %{"name" => "X", "value" => value})
      refute_value(changeset, value)
    end
  end

  describe "reading" do
    test "every member reads; a person no longer a member reads nothing", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})

      for level <- [:member, :admin] do
        %{scope: reader} = member_fixture(scope, level)
        assert {:ok, [%Secret{name: "API_KEY"}]} = Secrets.list_secrets(reader)
        assert {:ok, %Secret{}} = Secrets.get_secret(reader, secret.public_id)
      end

      %{scope: gone, membership: membership} = member_fixture(scope)
      {:ok, _} = Apiary.Organisations.remove_member(scope, membership.id)

      assert Secrets.list_secrets(gone) == {:error, :forbidden}
      assert Secrets.get_secret(gone, secret.public_id) == {:error, :forbidden}
    end
  end

  describe "who, where and the trail" do
    test "a member reads the secrets and changes none", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})
      %{scope: member} = member_fixture(scope)

      assert {:ok, [%Secret{name: "API_KEY"}]} = Secrets.list_secrets(member)
      assert Secrets.create_secret(member, %{name: "MINE", value: "x"}) == {:error, :forbidden}

      assert Secrets.create_secret(member, %{
               name: "MINE",
               values: [%{value_id: "shop", value: "x"}, %{value_id: "docs", value: "y"}]
             }) == {:error, :forbidden}

      assert {:ok, [%Secret{name: "API_KEY"}]} = Secrets.list_secrets(member)
      assert Secrets.update_secret(member, secret, %{name: "RENAMED"}) == {:error, :forbidden}
      assert Secrets.set_value(member, secret, nil, "x") == {:error, :forbidden}

      assert Secrets.add_value(member, secret, %{value_id: "a", value: "x", first_value_id: "b"}) ==
               {:error, :forbidden}

      assert Secrets.rename_value(member, secret, nil, "a") == {:error, :forbidden}
      assert Secrets.delete_secret(member, secret) == {:error, :forbidden}
      assert reveal(scope, secret) == {:ok, @value}
    end

    test "an admin changes them", %{scope: scope} do
      %{scope: admin} = member_fixture(scope, :admin)
      assert {:ok, secret} = Secrets.create_secret(admin, %{name: "API_KEY", value: @value})
      assert {:ok, _} = Secrets.delete_secret(admin, secret)
    end

    test "every workspace of the organisation reads and changes the same secrets", %{
      owner: owner,
      scope: scope
    } do
      secret = create!(scope, %{name: "API_KEY"})
      id = secret.id
      other = other_workspace(owner)

      assert {:ok, [%Secret{id: ^id}]} = Secrets.list_secrets(other)
      assert {:ok, %Secret{id: ^id}} = Secrets.get_secret(other, secret.public_id)
      assert {:ok, %{^id => []}} = Secrets.list_uses(other, [secret])

      assert {:ok, _} = Secrets.set_value(other, secret, nil, "rotated value")
      assert reveal(scope, secret) == {:ok, "rotated value"}

      # A member reads them from any workspace, and changes none.
      %{scope: member} = member_fixture(scope)
      member_elsewhere = workspace_scope(member.user, other.workspace)
      assert {:ok, [%Secret{id: ^id}]} = Secrets.list_secrets(member_elsewhere)
      assert Secrets.set_value(member_elsewhere, secret, nil, "x") == {:error, :forbidden}

      # The entries are the organisation's, with no workspace.
      assert [_created, %Entry{workspace_id: nil, organisation_id: organisation_id}] =
               trail(secret)

      assert organisation_id == scope.organisation.id
    end

    test "another organisation's secret is out of reach", %{scope: scope} do
      theirs = create!(scope, %{name: "THEIRS"})
      other = sign_up_fixture().scope

      assert Secrets.list_secrets(other) == {:ok, []}
      assert Secrets.get_secret(other, theirs.public_id) == {:error, :not_found}
      assert Secrets.update_secret(other, theirs, %{name: "MINE"}) == {:error, :not_found}
      assert Secrets.delete_secret(other, theirs) == {:error, :not_found}
      assert Secrets.set_value(other, theirs, nil, "x") == {:error, :not_found}

      assert Secrets.reveal_for_sealing(other.organisation, theirs.public_id, nil) ==
               {:error, :not_found}

      assert reveal(scope, theirs) == {:ok, @value}
    end

    test "get_secret/2 finds a secret by its public id only", %{scope: scope} do
      secret = create!(scope, %{name: "API_KEY"})

      assert {:ok, %Secret{name: "API_KEY", values: [%Value{nonce: nil}]}} =
               Secrets.get_secret(scope, secret.public_id)

      assert Secrets.get_secret(scope, secret.id) == {:error, :not_found}
      assert Secrets.get_secret(scope, "sec_0000000000000000") == {:error, :not_found}
      assert Secrets.get_secret(scope, nil) == {:error, :not_found}
    end

    test "every change leaves one entry by name and value id, never a value", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS", note: "Deploys"})
      {:ok, secret} = Secrets.update_secret(scope, secret, %{note: "Deploys the site"})
      {:ok, secret} = Secrets.set_value(scope, secret, nil, "second value")

      {:ok, secret} =
        Secrets.add_value(scope, secret, %{
          value_id: "bot",
          value: "bot value",
          first_value_id: "main"
        })

      {:ok, secret} = Secrets.rename_value(scope, secret, "bot", "robot")
      {:ok, secret} = Secrets.delete_value(scope, secret, "robot")
      {:ok, _} = Secrets.delete_secret(scope, secret)

      entries = trail(secret)
      assert Enum.all?(entries, &(&1.action == "secret.write" and &1.subject_kind == "secret"))

      assert Enum.map(entries, & &1.details["change"]) ==
               ~w(created updated value_set value_added value_renamed value_deleted deleted)

      assert Enum.all?(entries, &(&1.details["secret_id"] == secret.public_id))
      assert Enum.all?(entries, &(&1.details["name"] == "KEYS"))
      [created, updated, _set, added, renamed, deleted_value, deleted] = entries
      assert created.after["name"] == "KEYS"
      assert updated.before == %{"note" => "Deploys"}
      assert added.details["value_id"] == "bot"
      assert added.details["first_value_id"] == "main"
      assert {renamed.before, renamed.after} == {%{"value_id" => "bot"}, %{"value_id" => "robot"}}
      assert deleted_value.before == %{"value_id" => "robot"}
      assert deleted.before["name"] == "KEYS"

      kept = Jason.encode!(Enum.map(entries, &[&1.before, &1.after, &1.details]))
      for value <- [@value, "second value", "bot value"], do: refute(kept =~ value)
    end

    test "a change that changes nothing leaves no entry", %{scope: scope} do
      secret = create!(scope, %{name: "KEYS"})
      assert {:ok, _} = Secrets.update_secret(scope, secret, %{name: "KEYS"})
      assert {:ok, _} = Secrets.rename_value(scope, secret, nil, nil)
      assert length(trail(secret)) == 1
    end
  end
end

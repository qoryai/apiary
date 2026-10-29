defmodule Apiary.Secrets.InstanceTest do
  # `Apiary.Secrets.Instance`: an adapter's secret, its values replaced at each write under
  # one data key of the instance, read back only for that adapter, and deleted with it.
  # Not async: some tests change the instance's encryption secret or the adapters listed in
  # `QORY_INSTALLED_ADAPTERS`.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, KeyDerivation, Repo}
  alias Apiary.Nodes.Node

  alias Apiary.Secrets.{
    Cipher,
    Instance,
    InstanceDataKey,
    InstanceSecret,
    InstanceSecretValue,
    Reference
  }

  @moduletag needs: :factory

  @private_key "-----BEGIN PRIVATE KEY-----\nfixture-key-for-tests-only\n-----END PRIVATE KEY-----"
  @webhook_secret "fixture-webhook-secret-for-tests-only"

  setup do
    saved = Application.fetch_env!(:apiary, KeyDerivation)
    saved_list = Application.fetch_env(:apiary, :installed_adapters)

    on_exit(fn ->
      Application.put_env(:apiary, KeyDerivation, saved)

      case saved_list do
        {:ok, names} -> Application.put_env(:apiary, :installed_adapters, names)
        :error -> Application.delete_env(:apiary, :installed_adapters)
      end
    end)

    %{adapter: adapter_fixture(), other: adapter_fixture()}
  end

  defp values(pairs),
    do: for({id, value} <- pairs, do: %InstanceSecretValue{value_id: id, value: value})

  defp put(adapter, pairs, opts \\ []), do: Instance.put_app_values(adapter, values(pairs), opts)

  defp plain({:ok, %{revision: revision, values: values}}),
    do:
      {revision, for(%InstanceSecretValue{value_id: id, value: value} <- values, do: {id, value})}

  defp plain(other), do: other

  defp reveal(adapter), do: adapter |> Instance.reveal_app_values_for_sealing() |> plain()

  defp rows(adapter) do
    Repo.all(
      from v in InstanceSecretValue,
        join: s in InstanceSecret,
        on: s.id == v.secret_id,
        where: s.adapter_id == ^adapter.id,
        order_by: v.value_id
    )
  end

  describe "a write" do
    test "the first makes the instance's one data key, and the values read back", ctx do
      assert Repo.all(InstanceDataKey) == []

      assert {:ok, stored} =
               put(ctx.adapter, [{"signing-key", @private_key}, {"event-secret", @webhook_secret}])

      assert %{revision: 1, names: ["event-secret", "signing-key"], replaced: false} = stored
      assert %Reference{store: "builtin", entry: "sec_" <> _} = stored.reference

      assert [%InstanceDataKey{id: true, wrapping_key_id: key_id}] = Repo.all(InstanceDataKey)
      assert key_id == elem(KeyDerivation.key(:values), 0)

      assert %Node{secret_store: "builtin", secret_entry: entry} = Repo.get!(Node, ctx.adapter.id)
      assert entry == stored.reference.entry

      assert reveal(ctx.adapter) ==
               {1, [{"event-secret", @webhook_secret}, {"signing-key", @private_key}]}

      # A second adapter's write takes the same data key.
      assert {:ok, _stored} = put(ctx.other, [{"signing-key", "other"}])
      assert [%InstanceDataKey{}] = Repo.all(InstanceDataKey)
    end

    test "is stored encrypted, bound to its adapter, its secret and its value id", ctx do
      {:ok, stored} = put(ctx.adapter, [{"signing-key", @private_key}])
      [row] = rows(ctx.adapter)

      refute row.ciphertext =~ @private_key
      assert byte_size(row.nonce) == 12
      assert byte_size(row.ciphertext) == byte_size(@private_key) + 16

      {:ok, key} = unwrap(Repo.get!(InstanceDataKey, true))

      aad =
        Cipher.instance_value_aad(ctx.adapter.public_id, stored.reference.entry, "signing-key")

      assert Cipher.decrypt(key, aad, row.nonce, row.ciphertext) == {:ok, @private_key}
    end

    test "a replacement raises the revision and leaves no value of the one before", ctx do
      {:ok, first} = put(ctx.adapter, [{"signing-key", "one"}, {"event-secret", "two"}])
      [%{id: old_a}, %{id: old_b}] = rows(ctx.adapter)

      assert {:ok, second} = put(ctx.adapter, [{"signing-key", "three"}])
      assert %{revision: 2, names: ["signing-key"], replaced: true} = second
      assert second.reference == first.reference

      ids = Enum.map(rows(ctx.adapter), & &1.id)
      refute old_a in ids
      refute old_b in ids
      assert reveal(ctx.adapter) == {2, [{"signing-key", "three"}]}

      assert {:ok, %{revision: 3, names: []}} = put(ctx.adapter, [])
      assert rows(ctx.adapter) == []
      assert reveal(ctx.adapter) == {3, []}
      assert Repo.aggregate(InstanceSecret, :count) == 1
    end

    test "values outside their forms are refused, and nothing is written", ctx do
      for pairs <- [
            [{"Signing-Key", "x"}],
            [{".key", "x"}],
            [{"signing-key", ""}],
            [{"signing-key", "a" <> <<0>>}],
            [{"signing-key", <<0xFF>>}],
            [{"signing-key", String.duplicate("a", 16_385)}],
            [{"signing-key", "x"}, {"signing-key", "y"}],
            for(n <- 1..17, do: {"key-#{n}", "x"})
          ] do
        assert put(ctx.adapter, pairs) == {:error, :invalid}
      end

      assert {:ok, _stored} = put(ctx.adapter, for(n <- 1..16, do: {"key-#{n}", "x"}))
      assert {:ok, _stored} = put(ctx.adapter, [{"k", String.duplicate("é", 8192)}])

      assert Instance.put_app_values(ctx.adapter, [%{value_id: "k", value: "x"}]) ==
               {:error, :invalid}

      assert Instance.put_app_values(ctx.adapter, :none) == {:error, :invalid}
    end

    test "of an adapter deleted, or installed and no longer listed, is not found", ctx do
      {:ok, _deleted} = Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)
      assert put(ctx.adapter, [{"signing-key", "x"}]) == {:error, :not_found}

      name = "tracker-#{System.unique_integer([:positive])}"
      Application.put_env(:apiary, :installed_adapters, [name])
      installed = installed_adapter_fixture(name)
      assert {:ok, _stored} = put(installed, [{"signing-key", "x"}])

      Application.put_env(:apiary, :installed_adapters, [])
      assert put(installed, [{"signing-key", "y"}]) == {:error, :not_found}
      assert reveal(installed) == {1, [{"signing-key", "x"}]}
    end

    test "runs the caller's check first and its record last, in the transaction", ctx do
      assert put(ctx.adapter, [{"signing-key", "x"}], allowed: fn _ -> {:error, :forbidden} end) ==
               {:error, :forbidden}

      assert Repo.all(InstanceDataKey) == []

      assert put(ctx.adapter, [{"signing-key", "x"}],
               record: fn %Node{id: id}, %{revision: 1} ->
                 assert id == ctx.adapter.id
                 {:error, :recorded_nothing}
               end
             ) == {:error, :recorded_nothing}

      assert rows(ctx.adapter) == []
      assert %Node{secret_store: nil, secret_entry: nil} = Repo.get!(Node, ctx.adapter.id)
    end
  end

  describe "a reveal" do
    test "of an adapter that stored nothing has no value and no revision", ctx do
      assert reveal(ctx.adapter) == {nil, []}
    end

    test "finds the secret of this adapter, never another adapter's", ctx do
      {:ok, mine} = put(ctx.adapter, [{"signing-key", @private_key}])

      # The other adapter's reference set to this adapter's secret.
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.other.id),
          set: [secret_store: "builtin", secret_entry: mine.reference.entry]
        )

      log = capture_log(fn -> assert reveal(ctx.other) == {:error, :unavailable} end)
      assert log =~ "adapter_id=#{ctx.other.public_id}"
      refute log =~ @private_key
    end

    test "of a value moved to another adapter's secret does not decrypt", ctx do
      {:ok, _mine} = put(ctx.adapter, [{"signing-key", @private_key}])
      {:ok, theirs} = put(ctx.other, [{"signing-key", "theirs"}])
      [row] = rows(ctx.adapter)

      {1, _} =
        Repo.update_all(
          from(v in InstanceSecretValue,
            join: s in InstanceSecret,
            on: s.id == v.secret_id,
            where: s.public_id == ^theirs.reference.entry
          ),
          set: [nonce: row.nonce, ciphertext: row.ciphertext]
        )

      log = capture_log(fn -> assert reveal(ctx.other) == {:error, :unavailable} end)
      assert log =~ "adapter_id=#{ctx.other.public_id} value_id=signing-key"
      refute log =~ @private_key
    end

    test "under a data key wrapped by another secret is unavailable, and the log has no value",
         ctx do
      {:ok, _stored} = put(ctx.adapter, [{"signing-key", @private_key}])
      Application.put_env(:apiary, KeyDerivation, secret: :crypto.strong_rand_bytes(32))

      log = capture_log(fn -> assert reveal(ctx.adapter) == {:error, :unavailable} end)
      assert log =~ "the instance's data key cannot be unwrapped"
      refute log =~ @private_key

      log =
        capture_log(fn ->
          assert put(ctx.adapter, [{"signing-key", "x"}]) == {:error, :unavailable}
        end)

      assert log =~ "the instance's data key cannot be unwrapped"
    end
  end

  describe "the values" do
    test "inspect without the value, the nonce or the ciphertext", ctx do
      {:ok, _stored} = put(ctx.adapter, [{"signing-key", @private_key}])
      {:ok, %{values: [value]}} = Instance.reveal_app_values_for_sealing(ctx.adapter)
      [row] = rows(ctx.adapter)

      refute inspect(value) =~ @private_key
      refute inspect(row) =~ inspect(row.ciphertext)
      refute inspect(Repo.get!(InstanceDataKey, true)) =~ "wrapped_key: <<"
    end
  end

  describe "the adapter's deletion" do
    test "deletes its secret and its values, and clears its reference", ctx do
      {:ok, _stored} = put(ctx.adapter, [{"signing-key", "x"}])
      {:ok, _theirs} = put(ctx.other, [{"signing-key", "y"}])

      assert {:ok, deleted} = Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)
      assert %Node{secret_store: nil, secret_entry: nil} = deleted
      assert rows(ctx.adapter) == []
      refute Repo.exists?(from s in InstanceSecret, where: s.adapter_id == ^ctx.adapter.id)
      assert reveal(ctx.other) == {1, [{"signing-key", "y"}]}

      # Only this test's adapters: an entry a race test committed outside the sandbox, and
      # did not delete, is visible here too.
      deletions = fn ids ->
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.action == "adapter.delete" and e.subject_id in ^ids,
            select: {e.subject_id, e.details["app_values_deleted"]}
        )
      end

      assert deletions.([ctx.adapter.id]) == [{ctx.adapter.id, true}]

      bare = adapter_fixture()
      {:ok, _deleted} = Adapters.delete_adapter(instance_admin_scope(), bare)

      assert Enum.sort(deletions.([ctx.adapter.id, bare.id])) ==
               Enum.sort([{ctx.adapter.id, true}, {bare.id, false}])
    end
  end

  describe "the database" do
    test "refuses an instance secret of a node that is no adapter" do
      %{scope: scope} = sign_up_fixture()
      node = node_fixture(scope)

      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(%InstanceSecret{
            public_id: Apiary.PublicId.generate("sec"),
            adapter_id: node.id,
            name: "APP_VALUES",
            revision: 1
          })
        end

      assert error.constraint == "instance_secrets_adapter_check"
    end

    test "refuses a reference on a node that is no adapter, or to another store" do
      %{scope: scope} = sign_up_fixture()
      node = node_fixture(scope)

      for {store, entry, id} <- [
            {"builtin", "sec_0123456789abcdef", node.id},
            {"vault", "sec_0123456789abcdef", adapter_fixture().id},
            {"builtin", nil, adapter_fixture().id}
          ] do
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.update_all(from(n in Node, where: n.id == ^id),
              set: [secret_store: store, secret_entry: entry]
            )
          end

        assert error.postgres.constraint == "nodes_secret_reference_check"
      end
    end
  end

  describe "a reference" do
    test "is written and read as <store>:<entry>" do
      assert {:ok, reference} = Reference.parse("builtin:sec_0123456789abcdef")
      assert reference == %Reference{store: "builtin", entry: "sec_0123456789abcdef"}
      assert Reference.to_string(reference) == "builtin:sec_0123456789abcdef"
      assert Reference.builtin?(reference)

      assert {:ok, %Reference{store: "na_0123456789abcdef", entry: "vault/path:with colon"}} =
               Reference.parse("na_0123456789abcdef:vault/path:with colon")

      for value <- [
            "builtin",
            "builtin:",
            "builtin:secret",
            "vault:sec_0123456789abcdef",
            "na_0123456789abcdef:" <> String.duplicate("x", 257),
            "na_0123456789abcdef:tab\there",
            "na_0123456789abcdef:é",
            nil
          ] do
        assert Reference.parse(value) == :error, inspect(value)
      end
    end
  end

  defp unwrap(%InstanceDataKey{} = data_key) do
    {:ok, wrapping_key} = KeyDerivation.key(:values, data_key.wrapping_key_id)
    Cipher.unwrap(wrapping_key, data_key.wrapped_key, Cipher.instance_data_key_aad())
  end
end

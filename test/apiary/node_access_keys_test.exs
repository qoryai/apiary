defmodule Apiary.NodeAccessKeysTest do
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Nodes}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}

  @small_order "xxdqcD1N2E-6PAt2DRBnDyogU_osOczGTsf9d5KsA3o"
  @torsion_key "KH9r2npX9PKHPzv_Xl6pwmCmpjQ73zfHq800btWQTBE"
  @fixture_access_key "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, node: node_fixture(scope, %{name: "build-01"})}
  end

  defp entries(kind, id) do
    Repo.all(
      from e in Entry,
        where: e.subject_kind == ^kind and e.subject_id == ^id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp ledger(public_key), do: Repo.get(PublicKey, public_key)

  defp add(scope, node, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{label: unique_label(), public_key: ed25519_key_pair().encoded})
    AccessKeys.add_access_key(scope, node, attrs)
  end

  defp cannot_be_used?(changeset),
    do: errors_on(changeset)[:public_key] == ["this key cannot be used"]

  describe "a key made in a browser" do
    test "is active at once, with its fingerprint and its row in the ledger", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()

      assert {:ok, key} =
               AccessKeys.add_access_key(scope, node, %{
                 "label" => "build-01",
                 "public_key" => pair.encoded,
                 "allow_secrets" => "true"
               })

      assert AccessKey.status(key) == :active
      assert key.public_key == pair.public_key
      assert key.node_id == node.id
      assert key.arrived_by == :browser
      assert key.allow_secrets
      assert key.created_by_id == scope.user.id
      assert "ak_" <> _ = key.key_id
      assert String.length(AccessKey.fingerprint(key)) == 22

      assert %PublicKey{state: :current, key_id: key_id} = ledger(pair.public_key)
      assert key_id == key.key_id

      assert [entry] = entries("access_key", key.id)
      assert entry.action == "access_key.add"
      assert entry.after["fingerprint"] == AccessKey.fingerprint(key)
      assert entry.after["allow_secrets"] == true
    end

    test "has stored secrets off unless they are asked for", ctx do
      assert {:ok, key} = add(ctx.scope, ctx.node)
      refute key.allow_secrets
    end

    test "is refused with one message, whatever is wrong with it", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      <<short::binary-size(31), _::binary>> = pair.public_key

      for public_key <- [
            @small_order,
            @torsion_key,
            @fixture_access_key,
            Base.url_encode64(short, padding: false),
            Base.url_encode64(pair.public_key <> <<0>>, padding: false),
            Base.url_encode64(pair.public_key, padding: true),
            Base.encode64(pair.public_key),
            "",
            nil
          ] do
        assert {:error, changeset} =
                 AccessKeys.add_access_key(scope, node, %{label: "x", public_key: public_key})

        assert cannot_be_used?(changeset), inspect(public_key)
      end

      assert AccessKeys.list_for_node(scope, node) == []
      assert entries("node", node.id) |> Enum.map(& &1.action) == ["node.create"]
    end

    test "is added by its public key alone, marked as made in a browser", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()

      assert {:ok, key} =
               AccessKeys.add_access_key(scope, node, %{
                 "label" => "spot-runners",
                 "public_key" => pair.encoded
               })

      assert AccessKey.status(key) == :active
      assert key.arrived_by == :browser
      assert key.public_key == pair.public_key
      assert key.created_by_id == scope.user.id
      assert is_nil(key.enrolment_code_id)
      assert %PublicKey{state: :current} = ledger(pair.public_key)

      assert [entry] = entries("access_key", key.id)
      assert entry.action == "access_key.add"
      assert entry.after["arrived_by"] == "browser"
      assert entry.after["fingerprint"] == AccessKey.fingerprint(key)

      # Read back as it was written, and trusted at verification.
      assert Repo.get!(AccessKey, key.id).arrived_by == :browser

      assert {:ok, %AccessKey{arrived_by: :browser}} =
               AccessKeys.fetch_for_verification(key.key_id)
    end

    test "is no way to add a key as enrolled with a code, or as anything else", ctx do
      %{scope: scope, node: node} = ctx

      for arrived_by <- ["code", "paste", :code] do
        attrs = %{label: unique_label(), public_key: ed25519_key_pair().encoded}

        assert {:ok, key} =
                 AccessKeys.add_access_key(scope, node, Map.put(attrs, :arrived_by, arrived_by))

        assert key.arrived_by == :browser
        {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      end
    end

    test "is checked: the key checks, the ledger, the limit", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = add(scope, node)

      for public_key <- [
            @small_order,
            @fixture_access_key,
            Base.url_encode64(first.public_key, padding: false)
          ] do
        assert {:error, changeset} =
                 AccessKeys.add_access_key(scope, node, %{label: "x", public_key: public_key})

        assert cannot_be_used?(changeset)
      end

      %{access_key: _second} = browser_key_fixture(scope, node)

      assert {:error, :key_limit} =
               AccessKeys.add_access_key(scope, node, %{
                 label: "x",
                 public_key: ed25519_key_pair().encoded
               })
    end

    test "a member may not add one", ctx do
      %{scope: scope, node: node} = ctx
      %{scope: member} = member_fixture(scope, :member)

      assert {:error, :forbidden} =
               AccessKeys.add_access_key(member, node, %{
                 label: "x",
                 public_key: ed25519_key_pair().encoded
               })
    end

    test "its integrity code covers its arrival", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = browser_key_fixture(scope, node)

      assert AccessKey.verify_integrity(key) == :ok

      assert AccessKey.verify_integrity(%{key | arrived_by: :code}) == {:error, :mismatch}

      # The database keeps it fixed, as an enrolled key's.
      assert_raise Postgrex.Error, ~r/access_keys_fixed_at_insert/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [arrived_by: :code])
      end

      {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert revoked.arrived_by == :browser
      assert AccessKey.verify_integrity(Repo.get!(AccessKey, key.id)) == :ok
    end
  end

  describe "a ledger changed outside the application" do
    test "a key whose row is missing is revoked and deleted with its node all the same", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, made} = add(scope, node)
      %{access_key: enrolled} = enrolled_key_fixture(scope, node)
      {:ok, other} = add(scope, node_fixture(scope))

      Repo.delete_all(
        from p in PublicKey,
          where: p.public_key in ^[made.public_key, enrolled.public_key, other.public_key]
      )

      assert {:ok, _} = AccessKeys.revoke_access_key(scope, made)
      assert {:ok, _} = AccessKeys.revoke_access_key(scope, enrolled)

      assert %PublicKey{state: :tombstone, retired_reason: :revoked, key_id: key_id} =
               ledger(made.public_key)

      assert key_id == made.key_id
      assert %PublicKey{state: :tombstone, retired_reason: :revoked} = ledger(enrolled.public_key)

      other_node = Repo.get!(Apiary.Nodes.Node, other.node_id)
      assert {:ok, _} = Nodes.delete_node(scope, other_node)

      assert %PublicKey{state: :tombstone, retired_reason: :node_deleted} =
               ledger(other.public_key)
    end

    test "a key whose row names another key id is revoked, and its public key stays a tombstone",
         ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = add(scope, node)
      %{access_key: enrolled} = enrolled_key_fixture(scope, node)

      Repo.update_all(from(p in PublicKey, where: p.public_key == ^key.public_key),
        set: [key_id: "ak_0000000000000000"]
      )

      Repo.update_all(from(p in PublicKey, where: p.public_key == ^enrolled.public_key),
        set: [key_id: "ak_1111111111111111"]
      )

      assert {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert AccessKey.status(revoked) == :revoked

      assert %PublicKey{
               state: :tombstone,
               retired_reason: :revoked,
               key_id: "ak_0000000000000000"
             } =
               ledger(key.public_key)

      assert {:ok, _deleted} = Nodes.delete_node(scope, node)

      assert %PublicKey{state: :tombstone, retired_reason: :node_deleted} =
               ledger(enrolled.public_key)
    end
  end

  describe "the ledger" do
    test "refuses a key used by another key, on any node of any organisation", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      {:ok, _first} = add(scope, node, %{public_key: pair.encoded})

      other_node = node_fixture(scope)
      assert {:error, changeset} = add(scope, other_node, %{public_key: pair.encoded})
      assert cannot_be_used?(changeset)

      %{scope: elsewhere} = sign_up_fixture()

      assert {:error, changeset} =
               add(elsewhere, node_fixture(elsewhere), %{public_key: pair.encoded})

      assert cannot_be_used?(changeset)
    end

    test "keeps a revoked key's public key as a tombstone, refused for good", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      {:ok, key} = add(scope, node, %{public_key: pair.encoded})
      {:ok, _} = AccessKeys.revoke_access_key(scope, key)

      assert %PublicKey{state: :tombstone, retired_reason: :revoked, retired_at: %DateTime{}} =
               ledger(pair.public_key)

      assert {:error, changeset} = add(scope, node, %{public_key: pair.encoded})
      assert cannot_be_used?(changeset)
    end

    test "holds an enrolled key's public key as current, as a browser key's", ctx do
      %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, ctx.node)
      assert %PublicKey{state: :current, key_id: key_id} = ledger(pair.public_key)
      assert key_id == key.key_id
    end

    test "outlives the purge of the workspace, as tombstones", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      {:ok, _key} = add(scope, node, %{public_key: pair.encoded})

      assert AccessKeys.retire_public_keys(scope.organisation.id, scope.workspace.id) == 1
      assert AccessKeys.retire_public_keys(scope.organisation.id, scope.workspace.id) == 0

      assert %PublicKey{state: :tombstone, retired_reason: :workspace_deleted} =
               ledger(pair.public_key)
    end
  end

  describe "the limits" do
    test "a node holds two keys: a third is refused", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = add(scope, node)
      {:ok, _} = add(scope, node)

      assert add(scope, node) == {:error, :key_limit}
      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "a key made in a browser counts an enrolled key", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = add(scope, node)
      enrolled_key_fixture(scope, node)

      assert add(scope, node) == {:error, :key_limit}
    end

    test "a revoked key makes room", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = add(scope, node)
      {:ok, _} = add(scope, node)
      {:ok, _} = AccessKeys.revoke_access_key(scope, first)

      assert {:ok, _third} = add(scope, node)
      assert AccessKeys.key_limit() == 2
    end
  end

  describe "the label" do
    test "is unique among the node's keys in use", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = add(scope, node, %{label: "build-01"})

      assert {:error, changeset} = add(scope, node, %{label: "build-01"})
      assert errors_on(changeset).label == ["is already the label of a key of this node"]

      # Another node's key may have it.
      assert {:ok, _} = add(scope, node_fixture(scope), %{label: "build-01"})

      # Once the first is revoked, the node's next key may have it.
      {:ok, _} = AccessKeys.revoke_access_key(scope, first)
      assert {:ok, _} = add(scope, node, %{label: "build-01"})
    end

    test "a clash leaves nothing in the ledger", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = add(scope, node, %{label: "build-01"})
      pair = ed25519_key_pair()

      assert {:error, _changeset} =
               add(scope, node, %{label: "build-01", public_key: pair.encoded})

      assert ledger(pair.public_key) == nil
      assert {:ok, _} = add(scope, node, %{label: "build-02", public_key: pair.encoded})
    end
  end

  describe "stored secrets" do
    test "are fixed when the key is made", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = add(scope, node, %{allow_secrets: true})

      # No changeset after the insert casts it.
      changeset = AccessKeys.change_access_key(key, %{allow_secrets: false, label: "renamed"})
      refute Map.has_key?(changeset.changes, :allow_secrets)

      # Nor does the database let a change of it through, whatever writes it.
      assert_raise Postgrex.Error, ~r/access_keys_fixed_at_insert/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
          set: [allow_secrets: false]
        )
      end

      assert_raise Postgrex.Error, ~r/access_keys_fixed_at_insert/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
          set: [node_id: node_fixture(scope).id]
        )
      end
    end

    test "so are the public key, the arrival and the code it arrived by", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = enrolled_key_fixture(scope, node)
      %{code: other_code} = enrolled_key_fixture(scope, node_fixture(scope))

      for set <- [
            [public_key: ed25519_key_pair().public_key],
            [arrived_by: :browser],
            [enrolment_code_id: other_code.id],
            [enrolment_code_id: nil]
          ] do
        assert_raise Postgrex.Error, ~r/access_keys_fixed_at_insert/, fn ->
          Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: set)
        end
      end
    end

    test "come from the code's settings", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = enrolled_key_fixture(scope, node, %{allow_secrets: true})
      assert key.allow_secrets
      assert AccessKey.status(key) == :active
    end
  end

  describe "revoking" do
    test "a revocation retires a key, once, with its entry", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = add(scope, node)

      assert {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert AccessKey.status(revoked) == :revoked
      assert revoked.revoked_by_id == scope.user.id

      assert [_added, entry] = entries("access_key", key.id)
      assert entry.action == "access_key.revoke"
      assert entry.details["reason"] == "revoked"

      assert {:ok, ^revoked} = AccessKeys.revoke_access_key(scope, revoked)
      assert length(entries("access_key", key.id)) == 2
    end

    test "an enrolled key is revoked as a browser key is", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key, pair: pair} = enrolled_key_fixture(scope, node)

      assert {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert AccessKey.status(revoked) == :revoked
      assert AccessKeys.fetch_for_verification(key.key_id) == :error
      assert %PublicKey{state: :tombstone, retired_reason: :revoked} = ledger(pair.public_key)
    end
  end

  describe "the integrity code" do
    test "a key changed outside the application is refused at verification", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = enrolled_key_fixture(scope, node)

      assert {:ok, %AccessKey{node: %{id: node_id}}} =
               AccessKeys.fetch_for_verification(key.key_id)

      assert node_id == node.id

      # Its rate raised behind the application's back.
      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [rate: 1000])

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> AccessKeys.fetch_for_verification(key.key_id) end)

      assert result == {:error, :integrity}
      assert log =~ "does not match its integrity code key_id=#{key.key_id}"
    end

    test "a revoked key made live again outside the application is refused", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = add(scope, node)
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)
      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      assert AccessKeys.fetch_for_verification(key.key_id) == :error

      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
        set: [revoked_at: nil, revoked_by_id: nil]
      )

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> AccessKeys.fetch_for_verification(key.key_id) end)

      assert result == {:error, :integrity}
    end

    test "a code's row is coded too", ctx do
      {:ok, row, _code} = AccessKeys.create_enrolment_code(ctx.scope, ctx.node, %{})
      assert EnrolmentCode.verify_integrity(row) == :ok

      tampered = %{row | allow_secrets: true}
      assert EnrolmentCode.verify_integrity(tampered) == {:error, :mismatch}
    end
  end

  describe "enrolment codes" do
    test "a code is shown once and kept as its SHA-256, for 15 minutes", ctx do
      %{scope: scope, node: node} = ctx

      assert {:ok, row, code} =
               AccessKeys.create_enrolment_code(scope, node, %{
                 allow_secrets: true,
                 label_hint: "build-01"
               })

      assert code =~ ~r/\Aqec_[0-9A-HJKMNP-TV-Z]{26}\z/
      assert row.code_sha256 == :crypto.hash(:sha256, code)
      assert row.allow_secrets and row.label_hint == "build-01"
      assert DateTime.diff(row.expires_at, row.inserted_at, :second) in (15 * 60 - 1)..(15 * 60)
      refute inspect(row) =~ code

      assert [listed] = AccessKeys.list_enrolment_codes(scope, node)
      assert listed.id == row.id

      assert [entry] =
               entries("node", node.id) |> Enum.filter(&(&1.action == "access_key.create_code"))

      assert entry.after["code_id"] == row.id
      refute inspect(entry) =~ code
    end

    test "a label hint is a name Forager would send", ctx do
      assert {:error, changeset} =
               AccessKeys.create_enrolment_code(ctx.scope, ctx.node, %{label_hint: "-bad name"})

      assert errors_on(changeset).label_hint
    end

    test "a code is read as a person may type it" do
      code = EnrolmentCode.generate()
      "qec_" <> body = code

      grouped =
        "QEC_" <>
          (body
           |> String.downcase()
           |> String.graphemes()
           |> Enum.chunk_every(4)
           |> Enum.join("-"))

      assert EnrolmentCode.normalise(grouped) == {:ok, code}

      assert EnrolmentCode.normalise(
               "qec_" <> String.duplicate("o", 13) <> String.duplicate("l", 13)
             ) ==
               {:ok, "qec_" <> String.duplicate("0", 13) <> String.duplicate("1", 13)}

      assert EnrolmentCode.normalise("qec_" <> String.duplicate("U", 26)) == :error
      assert EnrolmentCode.normalise("qec_" <> String.duplicate("A", 25)) == :error
      assert EnrolmentCode.normalise("qrk_" <> String.duplicate("A", 26)) == :error
    end

    test "a cancelled code is outstanding no more, with its entry", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert {:ok, cancelled} = AccessKeys.cancel_code(scope, row)
      assert cancelled.cancelled_at
      assert EnrolmentCode.verify_integrity(cancelled) == :ok
      assert AccessKeys.list_enrolment_codes(scope, node) == []

      assert [entry] =
               entries("node", node.id) |> Enum.filter(&(&1.action == "access_key.cancel_code"))

      assert entry.details["code_id"] == row.id

      assert {:ok, _} = AccessKeys.cancel_code(scope, cancelled)
    end

    test "a used code is not cancelled", ctx do
      %{code: code} = enrolled_key_fixture(ctx.scope, ctx.node)
      assert AccessKeys.cancel_code(ctx.scope, code) == {:error, :used}
    end
  end

  describe "deleting the node" do
    test "revokes its keys and cancels its codes in the same transaction", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, made} = add(scope, node)
      %{access_key: enrolled, pair: enrolled_pair} = enrolled_key_fixture(scope, node)
      {:ok, outstanding, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert {:ok, _deleted} = Nodes.delete_node(scope, node)

      for key <- [made, enrolled] do
        assert AccessKeys.fetch_for_verification(key.key_id) == :error
        revoked = Repo.get!(AccessKey, key.id)
        assert AccessKey.status(revoked) == :revoked
        assert AccessKey.verify_integrity(revoked) == :ok

        assert %PublicKey{state: :tombstone, retired_reason: :node_deleted} =
                 ledger(revoked.public_key)

        assert [entry] =
                 entries("access_key", key.id) |> Enum.filter(&(&1.action == "access_key.revoke"))

        assert entry.details["reason"] == "node_deleted"
      end

      assert Repo.get!(EnrolmentCode, outstanding.id).cancelled_at

      assert [entry] = entries("node", node.id) |> Enum.filter(&(&1.action == "node.delete"))

      assert Enum.sort(entry.details["revoked_key_ids"]) ==
               Enum.sort([made.key_id, enrolled.key_id])

      # The public keys stay refused.
      assert {:error, changeset} =
               add(scope, node_fixture(scope), %{public_key: enrolled_pair.encoded})

      assert cannot_be_used?(changeset)
    end

    test "leaves no key to change on it", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: enrolled} = enrolled_key_fixture(scope, node)
      {:ok, _} = Nodes.delete_node(scope, node)

      assert AccessKeys.revoke_access_key(scope, enrolled) == {:error, :not_found}

      assert AccessKeys.add_access_key(scope, node, %{
               label: "x",
               public_key: ed25519_key_pair().encoded
             }) ==
               {:error, :not_found}

      assert AccessKeys.create_enrolment_code(scope, node, %{}) == {:error, :not_found}
    end
  end

  describe "who may" do
    test "owners and admins manage a node's keys; members do not", ctx do
      %{scope: owner, node: node} = ctx
      %{scope: admin} = member_fixture(owner, :admin)
      %{scope: member} = member_fixture(owner, :member)

      %{access_key: enrolled} = enrolled_key_fixture(owner, node)
      {:ok, active} = add(owner, node)
      {:ok, code, _} = AccessKeys.create_enrolment_code(owner, node, %{})

      assert AccessKeys.create_enrolment_code(member, node, %{}) == {:error, :forbidden}
      assert AccessKeys.cancel_code(member, code) == {:error, :forbidden}
      assert add(member, node) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(member, enrolled) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(member, active) == {:error, :forbidden}

      assert {:ok, _, _} = AccessKeys.create_enrolment_code(admin, node, %{})
      assert {:ok, _} = AccessKeys.cancel_code(admin, code)
      assert {:ok, _} = AccessKeys.revoke_access_key(admin, enrolled)
      assert {:ok, _} = AccessKeys.revoke_access_key(admin, active)
      assert {:ok, _} = add(admin, node)
    end

    test "another organisation's node, keys and codes are not reachable", ctx do
      %{scope: scope, node: node} = ctx
      enrolled_key_fixture(scope, node)
      {:ok, code, _} = AccessKeys.create_enrolment_code(scope, node, %{})
      %{scope: other} = sign_up_fixture()

      assert AccessKeys.list_for_node(other, node) == []
      assert AccessKeys.list_enrolment_codes(other, node) == []
      assert AccessKeys.cancel_code(other, code) == {:error, :not_found}
      assert AccessKeys.create_enrolment_code(other, node, %{}) == {:error, :not_found}
      assert add(other, node) == {:error, :not_found}
    end
  end

  describe "the workspace's node keys" do
    test "are the keys in use of its nodes and pools in use, each with its node, newest first",
         ctx do
      %{scope: scope, node: node} = ctx
      pool = pool_fixture(scope, %{name: "spot-runners"})
      gone = node_fixture(scope, %{name: "build-02"})

      {:ok, made} = add(scope, node, %{label: "build-01-a"})
      {:ok, revoked} = add(scope, node, %{label: "build-01-b"})
      {:ok, _} = AccessKeys.revoke_access_key(scope, revoked)
      %{access_key: enrolled} = enrolled_key_fixture(scope, pool, %{label: "spot-a"})
      {:ok, _} = add(scope, gone)
      {:ok, _} = Nodes.delete_node(scope, gone)

      other = workspace_scope(scope.user, workspace_fixture(scope.organisation))
      {:ok, _} = add(other, node_fixture(other))

      assert [first, second] = AccessKeys.list_workspace_node_keys(scope)
      assert {first.id, first.node.name} == {enrolled.id, "spot-runners"}
      assert {second.id, second.node.name} == {made.id, "build-01"}
    end
  end

  describe "the database" do
    test "holds every key to a public key, a node, a time received and an arrival", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = add(scope, node)

      assert_raise Postgrex.Error, ~r/not_null_violation/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [received_at: nil])
      end

      nullable =
        Repo.query!("""
        SELECT column_name, is_nullable FROM information_schema.columns
        WHERE table_name = 'access_keys'
        """).rows
        |> Map.new(fn [column, nullable] -> {column, nullable} end)

      for column <- ~w(public_key node_id received_at arrived_by),
          do: assert(nullable[column] == "NO", column)

      # No secret column is left, nor any of an approval.
      for gone <- ~w(secret_primary secret_secondary rotated_at approved_at approved_by_id
                     last_pending_at),
          do: refute(Map.has_key?(nullable, gone), gone)
    end

    test "holds a key's arrival to a browser, or a code with its code", ctx do
      %{scope: scope, node: node} = ctx

      [definition] =
        Repo.query!("""
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conname = 'access_keys_arrived_by_check'
        """).rows
        |> List.flatten()

      assert definition =~ "browser"
      refute definition =~ "paste"

      insert = fn arrived_by, code_id ->
        pair = ed25519_key_pair()

        key =
          %AccessKey{
            id: Ecto.UUID.generate(),
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id,
            node_id: node.id,
            key_id: AccessKey.generate_key_id(),
            public_key: pair.public_key,
            arrived_by: :browser,
            received_at: DateTime.utc_now()
          }
          |> AccessKey.insert_changeset(%{label: unique_label()})
          |> AccessKey.put_integrity()
          |> Ecto.Changeset.apply_changes()

        now = DateTime.utc_now()

        Repo.insert_all("access_keys", [
          %{
            id: Ecto.UUID.dump!(key.id),
            organisation_id: Ecto.UUID.dump!(key.organisation_id),
            workspace_id: Ecto.UUID.dump!(key.workspace_id),
            node_id: Ecto.UUID.dump!(key.node_id),
            key_id: key.key_id,
            label: key.label,
            public_key: key.public_key,
            allow_secrets: false,
            received_at: now,
            arrived_by: arrived_by,
            enrolment_code_id: code_id && Ecto.UUID.dump!(code_id),
            integrity_code: key.integrity_code,
            integrity_key_id: key.integrity_key_id,
            inserted_at: now,
            updated_at: now
          }
        ])
      end

      %{code: code} = enrolled_key_fixture(scope, node_fixture(scope))

      assert {1, _} = insert.("browser", nil)
      assert {1, _} = insert.("code", code.id)

      for {arrived_by, code_id} <- [{"paste", nil}, {"code", nil}, {"elsewhere", nil}, {"", nil}] do
        assert_raise Postgrex.Error, ~r/access_keys_arrived_by_check/, fn ->
          insert.(arrived_by, code_id)
        end
      end
    end

    test "a node's key names a node of its own workspace", ctx do
      %{scope: scope} = ctx
      %{scope: other} = sign_up_fixture()
      other_node = node_fixture(other)
      pair = ed25519_key_pair()

      changeset =
        %AccessKey{
          id: Ecto.UUID.generate(),
          organisation_id: scope.organisation.id,
          workspace_id: scope.workspace.id,
          node_id: other_node.id,
          key_id: AccessKey.generate_key_id(),
          public_key: pair.public_key,
          arrived_by: :browser,
          received_at: DateTime.utc_now()
        }
        |> AccessKey.insert_changeset(%{label: "x"})
        |> AccessKey.put_integrity()

      assert_raise Ecto.ConstraintError, ~r/access_keys_node_id_fkey/, fn ->
        Repo.insert(changeset)
      end
    end
  end

  describe "the key's part and the server's part" do
    @pin [
      %{"alg" => "ed25519", "public_key" => "current-key"},
      %{"alg" => "ed25519", "public_key" => "next-key"}
    ]

    test "the key's part is its id alone, nothing secret", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = browser_key_fixture(scope, node)

      assert AccessKeys.key_variable(key) == {"QORY_ACCESS_KEY_ID", key.key_id}
      assert AccessKeys.key_line(key) == "  access_key_id: #{key.key_id}"
    end

    test "the server's part is the pin and the address, and asks for no key" do
      assert AccessKeys.server_variable(@pin) ==
               {"QORY_APIARY_PUBLIC_KEY",
                ~s([{"alg":"ed25519","public_key":"current-key"},{"alg":"ed25519","public_key":"next-key"}])}

      assert AccessKeys.server_lines("https://apiary.example", @pin) == %{
               url: "  url: https://apiary.example",
               public_key: [
                 "  apiary_public_key:",
                 "    - {alg: ed25519, public_key: current-key}",
                 "    - {alg: ed25519, public_key: next-key}"
               ]
             }

      # The server's own pin by default, which the JSON reads back as, and the same lines.
      assert {"QORY_APIARY_PUBLIC_KEY", json} = AccessKeys.server_variable()
      assert Jason.decode!(json) == Apiary.SigningKey.apiary_public_key()

      assert AccessKeys.server_lines("https://apiary.example") ==
               AccessKeys.server_lines(
                 "https://apiary.example",
                 Apiary.SigningKey.apiary_public_key()
               )
    end
  end

  describe "a key enrolled is announced" do
    # A machine's enrolment with `code`, as `qory access-key enrol` posts it.
    defp enrol_request(code, pair) do
      now = System.os_time(:second)
      message = SignedMessage.enrolment(code, pair.encoded, "build-01", now)
      proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

      {:ok, request} =
        Enrolment.decode(
          Jason.encode!(%{
            "version" => 1,
            "code" => code,
            "name" => "build-01",
            "public_key" => pair.encoded,
            "timestamp" => now,
            "proof" => Ed25519.encode(proof)
          })
        )

      request
    end

    defp issued(scope, node) do
      {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {row, Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())}
    end

    # Every transaction's end, as the repo reports it, sent here in the order it happens.
    defp watch_commits do
      handler = "enrol-commits-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == parent and meta.query in ["commit", "rollback"],
            do: send(parent, {:repo, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp mailbox(acc \\ []) do
      receive do
        message -> mailbox([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "on the node's topic, once the enrolment committed, with the key's id and the node's alone",
         ctx do
      %{scope: scope, node: node} = ctx
      other = node_fixture(scope, %{name: "build-02"})
      {_row, code} = issued(scope, node)
      pair = ed25519_key_pair()

      :ok = AccessKeys.subscribe(scope, node)
      :ok = AccessKeys.subscribe(scope, other)
      watch_commits()

      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(enrol_request(code, pair))

      messages = mailbox()
      announced = {:key_enrolled, %{key_id: key.key_id, node_id: node.id}}

      # One announcement, on this node's topic alone.
      assert Enum.count(messages, &match?({:key_enrolled, _}, &1)) == 1
      assert announced in messages

      # The enrolment's transaction ended with its commit before the announcement: no
      # commit or rollback comes after it.
      {before, [^announced | after_]} = Enum.split_while(messages, &(&1 != announced))
      assert {:repo, "commit"} in before
      refute Enum.any?(after_, &match?({:repo, _}, &1))

      # Nothing secret: not the code, nor the public key, nor any secret.
      text = inspect(announced)
      refute text =~ code
      refute text =~ pair.encoded
      refute text =~ ~r/qak_|qec_/i
      assert AccessKeys.topic(scope.workspace.id, node.id) =~ node.id
    end

    test "a repeat of a used code announces nothing new; a refused enrolment nothing", ctx do
      %{scope: scope, node: node} = ctx
      {_row, code} = issued(scope, node)
      pair = ed25519_key_pair()
      :ok = AccessKeys.subscribe(scope, node)

      assert {:ok, key} = AccessKeys.enrol(enrol_request(code, pair))
      assert_received {:key_enrolled, %{key_id: key_id}}
      assert key_id == key.key_id

      # The same machine asks again, its answer lost: the same key, and no announcement.
      assert {:ok, again} = AccessKeys.enrol(enrol_request(code, pair))
      assert again.id == key.id
      refute_received {:key_enrolled, _}

      # The node full: the enrolment is refused and undone, and nothing is announced.
      browser_key_fixture(scope, node)
      {_row, full} = issued(scope, node)

      assert AccessKeys.enrol(enrol_request(full, ed25519_key_pair())) ==
               {:error, :key_limit}

      refute_received {:key_enrolled, _}

      # Another key on the used code: refused, nothing announced.
      assert AccessKeys.enrol(enrol_request(code, ed25519_key_pair())) ==
               {:error, :unauthorized}

      refute_received {:key_enrolled, _}
    end
  end

  describe "a code cancelled is announced" do
    test "on the node's topic, once the cancel committed, with the code's id and the node's alone",
         ctx do
      %{scope: scope, node: node} = ctx
      {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, %{})
      :ok = AccessKeys.subscribe(scope, node)
      watch_commits()

      assert {:ok, cancelled} = AccessKeys.cancel_code(scope, row)
      assert cancelled.cancelled_at

      messages = mailbox()
      announced = {:code_cancelled, %{code_id: row.id, node_id: node.id}}

      assert Enum.count(messages, &match?({:code_cancelled, _}, &1)) == 1
      {before, [^announced | after_]} = Enum.split_while(messages, &(&1 != announced))
      assert {:repo, "commit"} in before
      refute Enum.any?(after_, &match?({:repo, _}, &1))

      # The ids alone: not the code, nor its hash.
      text = inspect(announced, limit: :infinity, printable_limit: :infinity)
      refute text =~ code
      refute text =~ ~r/qec_/i
      refute text =~ inspect(row.code_sha256)
    end

    test "a code already cancelled, expired or used announces nothing", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, cancelled} = AccessKeys.cancel_code(scope, row)
      %{code: used} = enrolled_key_fixture(scope, node)
      :ok = AccessKeys.subscribe(scope, node)

      assert {:ok, _} = AccessKeys.cancel_code(scope, cancelled)
      assert AccessKeys.cancel_code(scope, used) == {:error, :used}
      refute_received {:code_cancelled, _}
    end
  end
end

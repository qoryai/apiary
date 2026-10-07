defmodule Apiary.NodeAccessKeysTest do
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Nodes}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Audit.Entry

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

  defp paste(scope, node, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{label: unique_label(), public_key: ed25519_key_pair().encoded})
    AccessKeys.add_access_key(scope, node, attrs)
  end

  defp cannot_be_used?(changeset),
    do: errors_on(changeset)[:public_key] == ["this key cannot be used"]

  describe "a pasted key" do
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
      assert key.arrived_by == :paste
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
      assert {:ok, key} = paste(ctx.scope, ctx.node)
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
  end

  describe "a key made in a browser" do
    test "is added by its public key as a paste is, marked as made in a browser", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()

      assert {:ok, key} =
               AccessKeys.add_access_key(
                 scope,
                 node,
                 %{"label" => "spot-runners", "public_key" => pair.encoded},
                 arrived_by: :browser
               )

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

    test "a paste is marked a paste, by default and when asked", ctx do
      %{scope: scope, node: node} = ctx

      for opts <- [[], [arrived_by: :paste]] do
        pair = ed25519_key_pair()
        attrs = %{label: unique_label(), public_key: pair.encoded}
        assert {:ok, key} = AccessKeys.add_access_key(scope, node, attrs, opts)
        assert key.arrived_by == :paste
        assert [entry] = entries("access_key", key.id)
        assert entry.after["arrived_by"] == "paste"
        {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      end
    end

    test "is no way to add a key as enrolled with a code", ctx do
      %{scope: scope, node: node} = ctx
      attrs = %{label: "x", public_key: ed25519_key_pair().encoded}

      for arrived_by <- [:code, :other, "browser", nil] do
        assert_raise ArgumentError, fn ->
          AccessKeys.add_access_key(scope, node, attrs, arrived_by: arrived_by)
        end
      end

      assert AccessKeys.list_for_node(scope, node) == []
    end

    test "is checked as a paste is: the key checks, the ledger, the limit", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, pasted} = paste(scope, node)

      for public_key <- [
            @small_order,
            @fixture_access_key,
            Base.url_encode64(pasted.public_key, padding: false)
          ] do
        assert {:error, changeset} =
                 AccessKeys.add_access_key(scope, node, %{label: "x", public_key: public_key},
                   arrived_by: :browser
                 )

        assert cannot_be_used?(changeset)
      end

      %{access_key: _second} = browser_key_fixture(scope, node)

      assert {:error, :key_limit} =
               AccessKeys.add_access_key(
                 scope,
                 node,
                 %{label: "x", public_key: ed25519_key_pair().encoded},
                 arrived_by: :browser
               )
    end

    test "a member may not add one", ctx do
      %{scope: scope, node: node} = ctx
      %{scope: member} = member_fixture(scope, :member)

      assert {:error, :forbidden} =
               AccessKeys.add_access_key(
                 member,
                 node,
                 %{label: "x", public_key: ed25519_key_pair().encoded},
                 arrived_by: :browser
               )
    end

    test "its integrity code covers its arrival", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = browser_key_fixture(scope, node)

      assert AccessKey.verify_integrity(key) == :ok

      for arrived_by <- [:paste, :code] do
        assert AccessKey.verify_integrity(%{key | arrived_by: arrived_by}) == {:error, :mismatch}
      end

      # The database keeps it fixed, as a paste's.
      assert_raise Postgrex.Error, ~r/access_keys_fixed_at_insert/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [arrived_by: :paste])
      end

      {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert revoked.arrived_by == :browser
      assert AccessKey.verify_integrity(Repo.get!(AccessKey, key.id)) == :ok
    end
  end

  describe "a ledger changed outside the application" do
    test "a key whose row is missing is revoked and deleted with its node all the same", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, pasted} = paste(scope, node)
      %{access_key: enrolled} = enrolled_key_fixture(scope, node)
      {:ok, other} = paste(scope, node_fixture(scope))

      Repo.delete_all(
        from p in PublicKey,
          where: p.public_key in ^[pasted.public_key, enrolled.public_key, other.public_key]
      )

      assert {:ok, _} = AccessKeys.revoke_access_key(scope, pasted)
      assert {:ok, _} = AccessKeys.revoke_access_key(scope, enrolled)

      assert %PublicKey{state: :tombstone, retired_reason: :revoked, key_id: key_id} =
               ledger(pasted.public_key)

      assert key_id == pasted.key_id
      assert %PublicKey{state: :tombstone, retired_reason: :revoked} = ledger(enrolled.public_key)

      other_node = Repo.get!(Apiary.Nodes.Node, other.node_id)
      assert {:ok, _} = Nodes.delete_node(scope, other_node)

      assert %PublicKey{state: :tombstone, retired_reason: :node_deleted} =
               ledger(other.public_key)
    end

    test "a key whose row names another key id is revoked, and its public key stays a tombstone",
         ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)
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
      {:ok, _first} = paste(scope, node, %{public_key: pair.encoded})

      other_node = node_fixture(scope)
      assert {:error, changeset} = paste(scope, other_node, %{public_key: pair.encoded})
      assert cannot_be_used?(changeset)

      %{scope: elsewhere} = sign_up_fixture()

      assert {:error, changeset} =
               paste(elsewhere, node_fixture(elsewhere), %{public_key: pair.encoded})

      assert cannot_be_used?(changeset)
    end

    test "keeps a revoked key's public key as a tombstone, refused for good", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      {:ok, key} = paste(scope, node, %{public_key: pair.encoded})
      {:ok, _} = AccessKeys.revoke_access_key(scope, key)

      assert %PublicKey{state: :tombstone, retired_reason: :revoked, retired_at: %DateTime{}} =
               ledger(pair.public_key)

      assert {:error, changeset} = paste(scope, node, %{public_key: pair.encoded})
      assert cannot_be_used?(changeset)
    end

    test "holds an enrolled key's public key as current, as a pasted one's", ctx do
      %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, ctx.node)
      assert %PublicKey{state: :current, key_id: key_id} = ledger(pair.public_key)
      assert key_id == key.key_id
    end

    test "outlives the purge of the workspace, as tombstones", ctx do
      %{scope: scope, node: node} = ctx
      pair = ed25519_key_pair()
      {:ok, _key} = paste(scope, node, %{public_key: pair.encoded})

      assert AccessKeys.retire_public_keys(scope.organisation.id, scope.workspace.id) == 1
      assert AccessKeys.retire_public_keys(scope.organisation.id, scope.workspace.id) == 0

      assert %PublicKey{state: :tombstone, retired_reason: :workspace_deleted} =
               ledger(pair.public_key)
    end
  end

  describe "the limits" do
    test "a node holds two keys: a third paste is refused", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = paste(scope, node)
      {:ok, _} = paste(scope, node)

      assert paste(scope, node) == {:error, :key_limit}
      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "a paste counts an enrolled key", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = paste(scope, node)
      enrolled_key_fixture(scope, node)

      assert paste(scope, node) == {:error, :key_limit}
    end

    test "a revoked key makes room", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = paste(scope, node)
      {:ok, _} = paste(scope, node)
      {:ok, _} = AccessKeys.revoke_access_key(scope, first)

      assert {:ok, _third} = paste(scope, node)
      assert AccessKeys.key_limit() == 2
    end
  end

  describe "the label" do
    test "is unique among the node's keys in use", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = paste(scope, node, %{label: "build-01"})

      assert {:error, changeset} = paste(scope, node, %{label: "build-01"})
      assert errors_on(changeset).label == ["is already the label of a key of this node"]

      # Another node's key may have it.
      assert {:ok, _} = paste(scope, node_fixture(scope), %{label: "build-01"})

      # Once the first is revoked, the node's next key may have it.
      {:ok, _} = AccessKeys.revoke_access_key(scope, first)
      assert {:ok, _} = paste(scope, node, %{label: "build-01"})
    end

    test "a clash leaves nothing in the ledger", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = paste(scope, node, %{label: "build-01"})
      pair = ed25519_key_pair()

      assert {:error, _changeset} =
               paste(scope, node, %{label: "build-01", public_key: pair.encoded})

      assert ledger(pair.public_key) == nil
      assert {:ok, _} = paste(scope, node, %{label: "build-02", public_key: pair.encoded})
    end
  end

  describe "stored secrets" do
    test "are fixed when the key is made", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node, %{allow_secrets: true})

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
            [arrived_by: :paste],
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
      {:ok, key} = paste(scope, node)

      assert {:ok, revoked} = AccessKeys.revoke_access_key(scope, key)
      assert AccessKey.status(revoked) == :revoked
      assert revoked.revoked_by_id == scope.user.id

      assert [_added, entry] = entries("access_key", key.id)
      assert entry.action == "access_key.revoke"
      assert entry.details["reason"] == "revoked"

      assert {:ok, ^revoked} = AccessKeys.revoke_access_key(scope, revoked)
      assert length(entries("access_key", key.id)) == 2
    end

    test "an enrolled key is revoked as a pasted one is", ctx do
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
      {:ok, key} = paste(scope, node)
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

    test "a label hint is a name a runner would send", ctx do
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
      {:ok, pasted} = paste(scope, node)
      %{access_key: enrolled, pair: enrolled_pair} = enrolled_key_fixture(scope, node)
      {:ok, outstanding, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert {:ok, _deleted} = Nodes.delete_node(scope, node)

      for key <- [pasted, enrolled] do
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
               Enum.sort([pasted.key_id, enrolled.key_id])

      # The public keys stay refused.
      assert {:error, changeset} =
               paste(scope, node_fixture(scope), %{public_key: enrolled_pair.encoded})

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
      {:ok, active} = paste(owner, node)
      {:ok, code, _} = AccessKeys.create_enrolment_code(owner, node, %{})

      assert AccessKeys.create_enrolment_code(member, node, %{}) == {:error, :forbidden}
      assert AccessKeys.cancel_code(member, code) == {:error, :forbidden}
      assert paste(member, node) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(member, enrolled) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(member, active) == {:error, :forbidden}

      assert {:ok, _, _} = AccessKeys.create_enrolment_code(admin, node, %{})
      assert {:ok, _} = AccessKeys.cancel_code(admin, code)
      assert {:ok, _} = AccessKeys.revoke_access_key(admin, enrolled)
      assert {:ok, _} = AccessKeys.revoke_access_key(admin, active)
      assert {:ok, _} = paste(admin, node)
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
      assert paste(other, node) == {:error, :not_found}
    end
  end

  describe "the workspace's node keys" do
    test "are the keys in use of its nodes and pools in use, each with its node, newest first",
         ctx do
      %{scope: scope, node: node} = ctx
      pool = pool_fixture(scope, %{name: "spot-runners"})
      gone = node_fixture(scope, %{name: "build-02"})

      {:ok, pasted} = paste(scope, node, %{label: "build-01-a"})
      {:ok, revoked} = paste(scope, node, %{label: "build-01-b"})
      {:ok, _} = AccessKeys.revoke_access_key(scope, revoked)
      %{access_key: enrolled} = enrolled_key_fixture(scope, pool, %{label: "spot-a"})
      {:ok, _} = paste(scope, gone)
      {:ok, _} = Nodes.delete_node(scope, gone)

      other = workspace_scope(scope.user, workspace_fixture(scope.organisation))
      {:ok, _} = paste(other, node_fixture(other))

      assert [first, second] = AccessKeys.list_workspace_node_keys(scope)
      assert {first.id, first.node.name} == {enrolled.id, "spot-runners"}
      assert {second.id, second.node.name} == {pasted.id, "build-01"}
    end
  end

  describe "the database" do
    test "holds every key to a public key, a node, a time received and an arrival", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)

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

    test "holds a key's arrival to a paste, a browser, or a code with its code", ctx do
      %{scope: scope, node: node} = ctx

      [definition] =
        Repo.query!("""
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conname = 'access_keys_arrived_by_check'
        """).rows
        |> List.flatten()

      assert definition =~ "browser"

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
            arrived_by: :paste,
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
      assert {1, _} = insert.("paste", nil)
      assert {1, _} = insert.("code", code.id)

      for {arrived_by, code_id} <- [{"code", nil}, {"elsewhere", nil}, {"", nil}] do
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
          arrived_by: :paste,
          received_at: DateTime.utc_now()
        }
        |> AccessKey.insert_changeset(%{label: "x"})
        |> AccessKey.put_integrity()

      assert_raise Ecto.ConstraintError, ~r/access_keys_node_id_fkey/, fn ->
        Repo.insert(changeset)
      end
    end
  end

  describe "variables/2" do
    test "is the key id and the pin as JSON, in that order, nothing secret", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = browser_key_fixture(scope, node)

      pin = [
        %{"alg" => "ed25519", "public_key" => "current-key"},
        %{"alg" => "ed25519", "public_key" => "next-key"}
      ]

      assert AccessKeys.variables(key, pin) == [
               {"QORY_ACCESS_KEY_ID", key.key_id},
               {"QORY_APIARY_PUBLIC_KEY",
                ~s([{"alg":"ed25519","public_key":"current-key"},{"alg":"ed25519","public_key":"next-key"}])}
             ]

      # The server's own pin by default, which the JSON reads back as.
      assert [{"QORY_ACCESS_KEY_ID", _}, {"QORY_APIARY_PUBLIC_KEY", json}] =
               AccessKeys.variables(key)

      assert Jason.decode!(json) == Apiary.SigningKey.apiary_public_key()

      # The runner file's variables are these, one line each.
      %{env: env} = AccessKeys.runner_lines(key, "https://apiary.example", pin)

      assert env ==
               Enum.map_join(AccessKeys.variables(key, pin), fn {name, value} ->
                 "#{name}=#{value}\n"
               end)
    end
  end

  describe "runner_lines/3" do
    test "is the runner file's server section and the CI variables, the pin in each", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)

      pin = [
        %{"alg" => "ed25519", "public_key" => "current-key"},
        %{"alg" => "ed25519", "public_key" => "next-key"}
      ]

      assert AccessKeys.runner_lines(key, "https://apiary.example", pin) == %{
               file: """
               server:
                 url: https://apiary.example
                 access_key_id: #{key.key_id}
                 apiary_public_key:
                   - {alg: ed25519, public_key: current-key}
                   - {alg: ed25519, public_key: next-key}
               """,
               env: """
               QORY_ACCESS_KEY_ID=#{key.key_id}
               QORY_APIARY_PUBLIC_KEY=[{"alg":"ed25519","public_key":"current-key"},{"alg":"ed25519","public_key":"next-key"}]
               """
             }

      # The pin is the server's own by default, and the JSON line reads back as it.
      %{env: env} = AccessKeys.runner_lines(key, "https://apiary.example")
      [_id, "QORY_APIARY_PUBLIC_KEY=" <> json] = String.split(env, "\n", trim: true)
      assert Jason.decode!(json) == Apiary.SigningKey.apiary_public_key()
    end
  end
end

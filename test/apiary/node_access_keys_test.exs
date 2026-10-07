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
    test "is approved at once, with its fingerprint and its row in the ledger", ctx do
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
      assert key.approved_by_id == scope.user.id
      assert key.secret_primary == nil
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

  describe "a ledger changed outside the application" do
    test "a key whose row is missing is revoked, rejected and deleted with its node all the same",
         ctx do
      %{scope: scope, node: node} = ctx
      {:ok, approved} = paste(scope, node)
      %{access_key: pending} = pending_key_fixture(scope, node)
      {:ok, other} = paste(scope, node_fixture(scope))

      Repo.delete_all(
        from p in PublicKey,
          where: p.public_key in ^[approved.public_key, pending.public_key, other.public_key]
      )

      assert {:ok, _} = AccessKeys.revoke_access_key(scope, approved)
      assert {:ok, _} = AccessKeys.reject(scope, pending)

      assert %PublicKey{state: :tombstone, retired_reason: :revoked, key_id: key_id} =
               ledger(approved.public_key)

      assert key_id == approved.key_id
      assert %PublicKey{state: :tombstone, retired_reason: :rejected} = ledger(pending.public_key)

      other_node = Repo.get!(Apiary.Nodes.Node, other.node_id)
      assert {:ok, _} = Nodes.delete_node(scope, other_node)

      assert %PublicKey{state: :tombstone, retired_reason: :node_deleted} =
               ledger(other.public_key)
    end

    test "a key whose row names another key id is revoked, and its public key stays a tombstone",
         ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)
      %{access_key: pending} = pending_key_fixture(scope, node)

      Repo.update_all(from(p in PublicKey, where: p.public_key == ^key.public_key),
        set: [key_id: "ak_0000000000000000"]
      )

      Repo.update_all(from(p in PublicKey, where: p.public_key == ^pending.public_key),
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
               ledger(pending.public_key)
    end

    test "an approval does not trust a key whose row is missing or not its own", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: missing} = pending_key_fixture(scope, node)
      Repo.delete_all(from p in PublicKey, where: p.public_key == ^missing.public_key)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> AccessKeys.approve(scope, missing) end)
      assert result == {:error, :integrity}
      assert log =~ missing.key_id
      assert AccessKey.status(Repo.get!(AccessKey, missing.id)) == :pending

      {:ok, _} = AccessKeys.reject(scope, missing)
      %{access_key: foreign} = pending_key_fixture(scope, node)

      Repo.update_all(from(p in PublicKey, where: p.public_key == ^foreign.public_key),
        set: [key_id: "ak_0000000000000000"]
      )

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> AccessKeys.approve(scope, foreign) end)
      assert result == {:error, :integrity}
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

    test "keeps a rejected key's public key as a tombstone, refused for good", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key, pair: pair} = pending_key_fixture(scope, node)
      {:ok, _} = AccessKeys.reject(scope, key)

      assert %PublicKey{state: :tombstone, retired_reason: :rejected} = ledger(pair.public_key)
      assert {:error, changeset} = paste(scope, node, %{public_key: pair.encoded})
      assert cannot_be_used?(changeset)
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
    test "a node holds two approved keys: a third paste is refused", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = paste(scope, node)
      {:ok, _} = paste(scope, node)

      assert paste(scope, node) == {:error, :key_limit}
      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "a paste counts the key awaiting approval", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, _} = paste(scope, node)
      pending_key_fixture(scope, node)

      assert paste(scope, node) == {:error, :key_limit}
    end

    test "an approval is refused while the node holds two approved keys", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = paste(scope, node)
      {:ok, _second} = paste(scope, node)
      %{access_key: pending} = pending_key_fixture(scope, node)

      assert AccessKeys.approve(scope, pending) == {:error, :key_limit}

      {:ok, _} = AccessKeys.revoke_access_key(scope, first)
      assert {:ok, approved} = AccessKeys.approve(scope, pending)
      assert AccessKey.status(approved) == :active
    end

    test "a revoked key makes room", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = paste(scope, node)
      {:ok, _} = paste(scope, node)
      {:ok, _} = AccessKeys.revoke_access_key(scope, first)

      assert {:ok, _third} = paste(scope, node)
      assert AccessKeys.key_limits() == %{approved: 2, pending: 1}
    end
  end

  describe "the label" do
    test "is unique among the node's keys in use", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, first} = paste(scope, node, %{label: "build-01"})

      assert {:error, changeset} = paste(scope, node, %{label: "build-01"})
      assert errors_on(changeset).label == ["is already the label of a key of this node"]

      # Another node's key, and today's key of the workspace, may have it.
      assert {:ok, _} = paste(scope, node_fixture(scope), %{label: "build-01"})
      assert %{access_key: _} = access_key_fixture(scope, %{label: "build-01"})

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
      %{access_key: key} = pending_key_fixture(scope, node)
      %{code: other_code} = pending_key_fixture(scope, node_fixture(scope))

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

    test "come from the code's settings, and survive the approval", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = pending_key_fixture(scope, node, %{allow_secrets: true})

      assert {:ok, approved} = AccessKeys.approve(scope, key)
      assert approved.allow_secrets
    end
  end

  describe "approving, rejecting and revoking" do
    test "an approval approves a pending key once, with its entry", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key, pair: pair} = pending_key_fixture(scope, node)
      assert AccessKey.status(key) == :pending
      assert %PublicKey{state: :pending} = ledger(pair.public_key)

      assert {:ok, approved} = AccessKeys.approve(scope, key)
      assert AccessKey.status(approved) == :active
      assert approved.approved_by_id == scope.user.id
      assert %PublicKey{state: :current} = ledger(pair.public_key)

      assert [entry] = entries("access_key", key.id)
      assert entry.action == "access_key.approve"
      assert entry.details["arrived_by"] == "code"
      assert entry.details["fingerprint"] == AccessKey.fingerprint(key)

      assert AccessKeys.approve(scope, approved) == {:error, :not_pending}
      assert AccessKeys.reject(scope, approved) == {:error, :not_pending}
    end

    test "a rejection retires a pending key, with its entry", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = pending_key_fixture(scope, node)

      assert {:ok, rejected} = AccessKeys.reject(scope, key)
      assert AccessKey.status(rejected) == :revoked
      assert rejected.revoked_by_id == scope.user.id
      assert [entry] = entries("access_key", key.id)
      assert entry.action == "access_key.reject"
      assert entry.details["reason"] == "rejected"

      assert AccessKeys.approve(scope, rejected) == {:error, :not_pending}
    end

    test "a revocation retires an approved key, once, with its entry", ctx do
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

    test "a pending key is rejected, not revoked", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = pending_key_fixture(scope, node)
      assert AccessKeys.revoke_access_key(scope, key) == {:error, :pending}
    end

    test "a node's key has no secret to rotate", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)

      assert AccessKeys.rotate_access_key(scope, key) == {:error, :not_found}
      assert AccessKeys.retire_previous_secret(scope, key) == {:error, :not_found}
    end
  end

  describe "the integrity code" do
    test "a key changed outside the application is refused at verification", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: key} = pending_key_fixture(scope, node)

      assert {:ok, %AccessKey{node: %{id: node_id}}} =
               AccessKeys.fetch_for_verification(key.key_id)

      assert node_id == node.id

      # Approved behind the application's back.
      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
        set: [approved_at: DateTime.utc_now()]
      )

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> AccessKeys.fetch_for_verification(key.key_id) end)

      assert result == {:error, :integrity}
      assert log =~ "does not match its integrity code key_id=#{key.key_id}"

      # Nor does an approval trust it.
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> AccessKeys.approve(scope, key) end)
      assert result == {:error, :integrity}
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

    test "a node's key verifies no request under a secret", ctx do
      {:ok, key} = paste(ctx.scope, ctx.node)
      assert AccessKey.secrets(key) == []
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
      %{code: code} = pending_key_fixture(ctx.scope, ctx.node)
      assert AccessKeys.cancel_code(ctx.scope, code) == {:error, :used}
    end
  end

  describe "deleting the node" do
    test "revokes its keys and cancels its codes in the same transaction", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, approved} = paste(scope, node)
      %{access_key: pending, pair: pending_pair} = pending_key_fixture(scope, node)
      {:ok, outstanding, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert {:ok, _deleted} = Nodes.delete_node(scope, node)

      for key <- [approved, pending] do
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
               Enum.sort([approved.key_id, pending.key_id])

      # The public keys stay refused.
      assert {:error, changeset} =
               paste(scope, node_fixture(scope), %{public_key: pending_pair.encoded})

      assert cannot_be_used?(changeset)
    end

    test "leaves no key to change on it", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: pending} = pending_key_fixture(scope, node)
      {:ok, _} = Nodes.delete_node(scope, node)

      assert AccessKeys.approve(scope, pending) == {:error, :not_found}

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

      %{access_key: pending} = pending_key_fixture(owner, node)
      {:ok, active} = paste(owner, node)
      {:ok, code, _} = AccessKeys.create_enrolment_code(owner, node, %{})

      assert AccessKeys.create_enrolment_code(member, node, %{}) == {:error, :forbidden}
      assert AccessKeys.cancel_code(member, code) == {:error, :forbidden}
      assert paste(member, node) == {:error, :forbidden}
      assert AccessKeys.approve(member, pending) == {:error, :forbidden}
      assert AccessKeys.reject(member, pending) == {:error, :forbidden}
      assert AccessKeys.revoke_access_key(member, active) == {:error, :forbidden}

      assert {:ok, _, _} = AccessKeys.create_enrolment_code(admin, node, %{})
      assert {:ok, _} = AccessKeys.cancel_code(admin, code)
      assert {:ok, _} = AccessKeys.approve(admin, pending)
      assert {:ok, _} = AccessKeys.revoke_access_key(admin, active)
      assert {:ok, _} = paste(admin, node)
    end

    test "every member still revokes today's keys", ctx do
      %{scope: member} = member_fixture(ctx.scope, :member)
      %{access_key: key} = access_key_fixture(ctx.scope)

      assert {:ok, revoked} = AccessKeys.revoke_access_key(member, key)
      assert [_created, entry] = entries("access_key", key.id)
      assert entry.action == "access_key.revoke_secret_key"
      assert AccessKey.status(revoked) == :revoked
    end

    test "another organisation's node, keys and codes are not reachable", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: pending} = pending_key_fixture(scope, node)
      {:ok, code, _} = AccessKeys.create_enrolment_code(scope, node, %{})
      %{scope: other} = sign_up_fixture()

      assert AccessKeys.list_for_node(other, node) == []
      assert AccessKeys.list_enrolment_codes(other, node) == []
      assert AccessKeys.approve(other, pending) == {:error, :not_found}
      assert AccessKeys.reject(other, pending) == {:error, :not_found}
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

      {:ok, approved} = paste(scope, node, %{label: "build-01-a"})
      {:ok, revoked} = paste(scope, node, %{label: "build-01-b"})
      {:ok, _} = AccessKeys.revoke_access_key(scope, revoked)
      %{access_key: rejected} = pending_key_fixture(scope, node)
      {:ok, _} = AccessKeys.reject(scope, rejected)
      %{access_key: pending} = pending_key_fixture(scope, pool, %{label: "spot-a"})
      {:ok, _} = paste(scope, gone)
      {:ok, _} = Nodes.delete_node(scope, gone)
      access_key_fixture(scope)

      other = workspace_scope(scope.user, workspace_fixture(scope.organisation))
      {:ok, _} = paste(other, node_fixture(other))

      assert [first, second] = AccessKeys.list_workspace_node_keys(scope)
      assert {first.id, first.node.name} == {pending.id, "spot-runners"}
      assert {second.id, second.node.name} == {approved.id, "build-01"}
    end
  end

  describe "the workspace's keys of today" do
    test "are listed without a node's keys, as the settings page has them", ctx do
      %{scope: scope, node: node} = ctx
      %{access_key: today} = access_key_fixture(scope)
      {:ok, node_key} = paste(scope, node)

      assert Enum.map(AccessKeys.list_access_keys(scope), & &1.id) == [today.id]
      assert_raise Ecto.NoResultsError, fn -> AccessKeys.get_access_key!(scope, node_key.id) end
      assert [listed] = AccessKeys.list_for_node(scope, node)
      assert listed.id == node_key.id
    end
  end

  describe "the database" do
    test "holds a public key to a node, and a row to one credential", ctx do
      %{scope: scope, node: node} = ctx
      {:ok, key} = paste(scope, node)

      assert_raise Postgrex.Error, ~r/access_keys_credential_check/, fn ->
        Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
          set: [secret_primary: "not-a-secret"]
        )
      end

      %{access_key: today} = access_key_fixture(scope)

      assert_raise Postgrex.Error,
                   ~r/access_keys_node_key_check|access_keys_credential_check/,
                   fn ->
                     Repo.update_all(from(k in AccessKey, where: k.id == ^today.id),
                       set: [secret_primary: nil]
                     )
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

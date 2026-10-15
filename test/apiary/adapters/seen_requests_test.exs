defmodule Apiary.Adapters.SeenRequestsTest do
  # The signatures of adapters' accepted requests (`Apiary.Adapters.SeenRequests`): a
  # signature accepted once is seen the second time, per key, kept for its time, and
  # deleted after it by the purge job. Two inserts at once are
  # `Apiary.Adapters.FeedRacesTest`'s.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters.{SeenRequests, SeenRequestsPurge}

  @moduletag needs: :factory

  @now 1_792_065_600

  setup do
    %{scope: scope} = sign_up_fixture()
    adapter = adapter_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, adapter)
    %{access_key: other} = enrolled_key_fixture(scope, adapter)
    %{scope: scope, key: key, other: other}
  end

  defp signature, do: :crypto.strong_rand_bytes(64)

  defp expires_at(key, signature) do
    Repo.one(
      from s in "adapter_seen_requests",
        where: s.access_key_id == type(^key.id, :binary_id) and s.signature == ^signature,
        select: type(s.expires_at, :utc_datetime_usec)
    )
  end

  test "a signature is accepted once per key", ctx do
    signature = signature()
    assert SeenRequests.record(ctx.key, signature, @now, @now) == :ok
    assert SeenRequests.record(ctx.key, signature, @now, @now) == :seen
    assert SeenRequests.record(ctx.key, signature, @now + 60, @now + 60) == :seen
    assert SeenRequests.record(ctx.other, signature, @now, @now) == :ok
  end

  test "is kept from its time or from now, whichever is later, for the retention", ctx do
    early = signature()
    late = signature()
    assert SeenRequests.record(ctx.key, early, @now - 300, @now) == :ok
    assert SeenRequests.record(ctx.key, late, @now + 300, @now) == :ok

    assert DateTime.to_unix(expires_at(ctx.key, early)) == @now + SeenRequests.retention()

    assert DateTime.to_unix(expires_at(ctx.key, late)) == @now + 300 + SeenRequests.retention()
    assert SeenRequests.retention() >= 600
  end

  test "the purge deletes the signatures past their time and keeps the others", ctx do
    old = signature()
    fresh = signature()
    now = System.os_time(:second)
    assert SeenRequests.record(ctx.key, old, now - 2000, now - 2000) == :ok
    assert SeenRequests.record(ctx.key, fresh, now, now) == :ok

    assert SeenRequests.purge(DateTime.utc_now()) >= 1
    assert expires_at(ctx.key, old) == nil
    assert %DateTime{} = expires_at(ctx.key, fresh)
    assert SeenRequests.record(ctx.key, fresh, now, now) == :seen
  end

  test "the purge job runs the purge, as the instance's work", ctx do
    old = signature()
    now = System.os_time(:second)
    assert SeenRequests.record(ctx.key, old, now - 2000, now - 2000) == :ok
    assert :ok = perform_job(SeenRequestsPurge, %{})
    assert expires_at(ctx.key, old) == nil
  end

  test "the table holds a signature of 64 bytes, and goes with the key", ctx do
    row = %{
      organisation_id: Ecto.UUID.dump!(ctx.scope.organisation.id),
      access_key_id: Ecto.UUID.dump!(ctx.key.id),
      signature: :crypto.strong_rand_bytes(63),
      expires_at: DateTime.utc_now()
    }

    %Postgrex.Error{postgres: %{constraint: constraint}} =
      assert_raise(Postgrex.Error, fn -> Repo.insert_all("adapter_seen_requests", [row]) end)

    assert constraint == "adapter_seen_requests_signature_check"

    signature = signature()
    assert SeenRequests.record(ctx.key, signature, @now, @now) == :ok
    Repo.delete!(ctx.key)
    assert expires_at(ctx.key, signature) == nil
  end

  defp perform_job(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: Repo)
  end
end

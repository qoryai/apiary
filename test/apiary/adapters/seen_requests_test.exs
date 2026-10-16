defmodule Apiary.Adapters.SeenRequestsTest do
  # The replay store of adapters' requests: a signature is accepted once per key, kept
  # until `max(time, now) + retention/0`, and purged after, by the job the crontab runs.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.NodesFixtures

  alias Apiary.Adapters.{SeenRequests, SeenRequestsPurge}

  @moduletag needs: :factory

  setup do
    %{access_key: key} = connectable_adapter_fixture()
    %{key: key}
  end

  defp signature, do: :crypto.strong_rand_bytes(64)

  defp expires_at(key, signature) do
    Repo.one!(
      from(s in "adapter_seen_requests",
        where: s.access_key_id == type(^key.id, :binary_id) and s.signature == ^signature,
        select: s.expires_at
      )
    )
    |> DateTime.from_naive!("Etc/UTC")
  end

  test "a signature is accepted once per key, and kept from the later of its time and now",
       %{key: key} do
    %{access_key: other} = connectable_adapter_fixture()
    signature = signature()
    now = 1_792_065_600

    assert SeenRequests.record(key, signature, now - 200, now) == :ok
    assert SeenRequests.record(key, signature, now - 200, now + 1) == :seen
    assert SeenRequests.record(other, signature, now - 200, now) == :ok

    assert DateTime.to_unix(expires_at(key, signature)) == now + SeenRequests.retention()

    future = signature()
    assert SeenRequests.record(key, future, now + 250, now) == :ok
    assert DateTime.to_unix(expires_at(key, future)) == now + 250 + SeenRequests.retention()

    # A row outlives the window of its request on every clock the window allows.
    assert SeenRequests.retention() > 300
  end

  test "purge/1 deletes the rows past their time, and the job runs it", %{key: key} do
    now = System.os_time(:second)
    old = signature()
    fresh = signature()
    :ok = SeenRequests.record(key, old, now - 4000, now - 3000)
    :ok = SeenRequests.record(key, fresh, now, now)

    assert :ok = perform_job(SeenRequestsPurge, %{})

    assert Repo.aggregate(from(s in "adapter_seen_requests"), :count) == 1
    assert SeenRequests.record(key, fresh, now, now) == :seen
    assert SeenRequests.purge(DateTime.utc_now()) == 0
  end
end

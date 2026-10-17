defmodule ApiaryWeb.Contract.PoolClaimController do
  @moduledoc false

  # `POST /v1/pools/claim`, with which a node pool's starter claims a run waiting in its
  # workspace's queue (the provisioner contract's `claim.schema.json`). Reached only
  # through `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`, which verifies the
  # request under the pool's access key, refuses what comes before the body, and signs the
  # answer but a `401`. The body is read raw, up to 1 MiB (`ApiaryWeb.Contract.RawBody`).
  #
  # Then, in order:
  #
  #   1. a body the contract refuses is `400` `invalid_request`
  #      (`Apiary.Dispatches.Wire.claim/1`);
  #   2. a `time` more than 300 seconds from the clock, either way, or a request whose
  #      signature was accepted before, is `401`, unsigned
  #      (`ApiaryWeb.Contract.AdapterRequest.accept/2`), before anything is looked up;
  #   3. a `pool_id` other than the key's node pool is `403` `forbidden`, the same answer
  #      as any refusal of `Apiary.Access`: the pool, the workspace and the organisation
  #      are the key's alone, never the body's;
  #   4. the claim (`Apiary.Dispatches.claim/2`): the key read again, revoked or of an
  #      organisation out of use since, `401`, unsigned; `dispatch.claim` refused, `403`
  #      `forbidden`; the pool's choice of gateway leading to none, `409` `no_gateway`;
  #   5. a run claimed is `200`, signed: the contract's `claim-answer.schema.json`, its
  #      `revision` the request's, inside the signed body.
  #
  # **The hold.** While the pool can claim nothing, its workspace's queue empty or the
  # pool at its instance limit, the request is held, up to its `wait_seconds`: it listens
  # on its workspace's topic (`Apiary.Dispatches.subscribe/1`) and tries again each time
  # it is told of a change there, and at each poll besides, then answers `204`, signed,
  # with no body, at the end of the hold. Every try reads the key again and asks
  # `dispatch.claim` again, so a key revoked, or an organisation out of use, while the
  # request waits is refused before a dispatch is handed out. `wait_seconds` 0 tries once.
  # A key holds at most `holds_per_key/0` requests at once, 2, as a key reading its change
  # feed does (`ApiaryWeb.Contract.ChangesController`): a request that would be a third
  # hold of its key is answered at once as a hold that ended, `204`. A request that claims
  # a run at its first try is no hold. Each hold takes a slot of the key, `{key id, n}`,
  # in the unique `Registry` `Holds`: the hold's process gives it back when the hold ends,
  # however it ends, and the registry frees it when the process exits.
  #
  # How long a hold lasts at most and how often it tries again besides are `hold` and
  # `poll`, in milliseconds, of `config :apiary, ApiaryWeb.Contract.PoolClaimController`,
  # 25,000 and 1,000 unless set. Nothing here logs a header, the body or a signature.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.{Dispatches, WorkItems}
  alias Apiary.Dispatches.Wire
  alias ApiaryWeb.Contract.AdapterRequest

  @hold 25_000
  @poll 1_000
  @holds_per_key 2
  @holds __MODULE__.Holds

  @doc false
  def create(conn, _params) do
    with {:ok, body} <- Wire.decode(conn.assigns.raw_body),
         {:ok, claim} <- Wire.claim(body),
         {:ok, conn} <- AdapterRequest.accept(conn, claim.time) do
      accepted(conn, claim)
    else
      :error -> refuse(conn, 400, "invalid_request")
      :unauthorized -> refuse(conn, 401, "unauthorized")
    end
  end

  # The claim of a request accepted: `conn` is the one `accept/2` marked.
  defp accepted(conn, claim) do
    key = conn.assigns.access_key

    with :ok <- same_pool(claim.pool_id, key),
         {:ok, %{} = claimed} <- claim(key, claim.wait_seconds) do
      answer(conn, claimed)
    else
      {:ok, :none} -> send_resp(conn, 204, "")
      {:error, :unauthorized} -> refuse(conn, 401, "unauthorized")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :no_gateway} -> refuse(conn, 409, "no_gateway")
    end
  end

  # How many requests a key holds at once.
  @doc false
  @spec holds_per_key() :: pos_integer
  def holds_per_key, do: @holds_per_key

  # No `pool_id`, or the key's node pool's; any other is refused as an unknown one is.
  defp same_pool(nil, _key), do: :ok

  defp same_pool(pool_id, %AccessKey{node: %{public_id: public_id}})
       when is_binary(public_id) and pool_id == public_id,
       do: :ok

  defp same_pool(_pool_id, _key), do: {:error, :forbidden}

  defp claim(key, 0), do: Dispatches.claim(key, Dispatches.now())

  defp claim(%AccessKey{workspace_id: workspace_id} = key, wait_seconds) do
    settings = Application.get_env(:apiary, __MODULE__) || []
    hold = min(wait_seconds * 1_000, Keyword.get(settings, :hold, @hold))
    poll = Keyword.get(settings, :poll, @poll)

    # Listening before the first try, so no change told between the try and the wait is
    # missed; and no longer once the request is answered, as the process may serve the
    # connection's next request.
    :ok = Dispatches.subscribe(workspace_id)

    try do
      case Dispatches.claim(key, Dispatches.now()) do
        {:ok, :none} = none -> hold(key, none, now() + hold, poll)
        other -> other
      end
    after
      Dispatches.unsubscribe(workspace_id)
      flush()
    end
  end

  # Holds while a slot of the key is free; a key with none answers at once.
  defp hold(%AccessKey{id: key_id} = key, none, deadline, poll) do
    case take_slot(key_id) do
      nil ->
        none

      slot ->
        try do
          wait(key, deadline, poll)
        after
          Registry.unregister(@holds, slot)
        end
    end
  end

  # The first free slot of the key, taken by this process, or nil when every one is held.
  defp take_slot(key_id) do
    Enum.find_value(1..@holds_per_key, fn n ->
      case Registry.register(@holds, {key_id, n}, nil) do
        {:ok, _owner} -> {key_id, n}
        {:error, {:already_registered, _pid}} -> nil
      end
    end)
  end

  # Waits for a change told, or the poll, then tries again, until a try claims a run or
  # is refused, or the deadline passes.
  defp wait(key, deadline, poll) do
    case deadline - now() do
      left when left > 0 ->
        receive do
          {Dispatches, :changed} -> flush()
        after
          min(poll, left) -> :ok
        end

        case Dispatches.claim(key, Dispatches.now()) do
          {:ok, :none} -> wait(key, deadline, poll)
          other -> other
        end

      _passed ->
        {:ok, :none}
    end
  end

  # The changes told meanwhile, which one try covers.
  defp flush do
    receive do
      {Dispatches, :changed} -> flush()
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp answer(conn, %{dispatch: dispatch, run: run, work_item: work_item, pool: pool}) do
    body =
      Jason.encode!(
        Jason.OrderedObject.new([
          {"version", 1},
          {"revision", conn.assigns.contract_version},
          {"dispatch_id", dispatch.public_id},
          {"run_id", run.run_id},
          {"pool_id", pool.public_id},
          {"lease_until", time(dispatch.lease_until)},
          {"step", run.step},
          {"access", access(run.step)},
          {"target",
           Jason.OrderedObject.new([
             {"system", work_item.target_system},
             {"path", work_item.target_path}
           ])},
          {"work_item",
           Jason.OrderedObject.new([
             {"id", work_item.public_id},
             {"url", WorkItems.stable_url(work_item)},
             {"title", work_item.title}
           ])}
        ])
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # What a run of a step may do on its target: an explore run reads.
  defp access("explore"), do: "read"

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end

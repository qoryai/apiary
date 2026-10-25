defmodule Apiary.Adapters.Calls do
  # Qory Apiary's calls to an adapter (the integration contract's `definitions.schema.json`,
  # "The control plane also calls the adapter"): a POST of `application/json` to the
  # adapter's `call_url` followed by the call's path, signed under the instance's signing
  # key, whose answer the adapter signs under its access key.
  #
  # `call/4` makes one call, in this order:
  #
  #   1. the address is checked, resolved and pinned (`Apiary.Adapters.CallAddress`);
  #   2. the body is `version` 1, `time`, then the call's members in order (`body/2`), at
  #      most `max_call` bytes (256 KiB), else the call fails `:too_large` unsent. `time`
  #      is in UTC to the second, and later than the time of every identical call before
  #      it, to the same adapter and path with the same members, on this node
  #      (`Apiary.Adapters.CallClock`), so no two calls to an adapter sign the same bytes,
  #      which its replay check would refuse. A time more than 60 seconds ahead of the
  #      clock waits until it is not, within the call's time, else the call takes no time
  #      and fails `:timeout` unsent;
  #   3. it is signed (`signature/4`): the headers `X-Qory-Adapter-Id` (the adapter's
  #      public id), `X-Qory-Instance-Id` (the instance id of the adapter's start-up that
  #      declared the `call_url`), `X-Qory-Contract-Version` (1) and
  #      `X-Qory-Signature-Ed25519`, over `Apiary.Contract.SignedMessage.call/5`;
  #   4. it is sent to the pinned address, with the host kept for `Host`, SNI and the
  #      certificate's check. No redirect is followed, no body is decompressed, and an
  #      answer over `max_answer` bytes (1 MiB), counted as it arrives, is refused;
  #   5. the answer counts only when its `X-Qory-Signature-Ed25519` verifies under an
  #      active access key of the adapter (`signed?/5`), over
  #      `Apiary.Contract.SignedMessage.call_answer/3`, bound to the call's signature. A
  #      signed 200 whose body is a JSON object with `version` 1 and `revision` 1, the
  #      call's `X-Qory-Contract-Version`, is `{:ok, body}`; a signed refusal is `:refused`
  #      with its code and status; an unsigned 401 is `:refused`, `unauthorized`; an
  #      unsigned 502, 503 or 504 is `:unreachable`; every other answer, one with a status
  #      outside 100 to 599 and one over `max_answer` included, is `:invalid_answer`.
  #
  # **Time.** The whole call, the lookup of the adapter's host and the retry included, has
  # `total` milliseconds (10 seconds),
  # and each attempt at most `attempt` (5 seconds). One more attempt follows, built anew
  # with a later time and signed again, after 250 to 500 milliseconds, when an attempt
  # made no connection, broke before an answer, timed out, or got an unsigned 502, 503 or
  # 504 from a proxy; and after a signed 429 whose `Retry-After` seconds end before the
  # call's time does. No other answer is tried again, and no attempt starts after the
  # call's time ends.
  #
  # A failure is `{:error, %Apiary.Adapters.CallFailure{}}`, with one log line: the
  # adapter's public id, the path, the cause and the duration, never a body, a header's
  # value or a signature.
  #
  # The settings are `config :apiary, Apiary.Adapters.Calls`, and `opts` for one call:
  # `total`, `attempt` and `retry_wait` (`{min, max}`) in milliseconds, `max_call` and
  # `max_answer` in bytes, `resolver` (`Apiary.Adapters.CallAddress`), and `req_options`,
  # merged into each request's.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Apiary.{AccessKeys, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{CallAddress, CallClock, CallFailure, CallWire, RunCredential, Wire}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Integrations.Fetch.Address
  alias Apiary.Nodes.Node

  @revision 1
  @total 10_000
  @attempt 5_000
  @retry_wait {250, 500}
  @max_call 256 * 1024
  @max_answer 1024 * 1024
  # The time of a call's body for its size and its clock key (`CallClock.key/3`).
  @no_time ~U[2026-01-01 00:00:00Z]
  @refusal_code ~r/\A[a-z_]{1,64}\z/
  @paths ["run-credential", "resolve", "read"]

  @doc false
  # The contract revision Qory Apiary builds its calls for, `X-Qory-Contract-Version`.
  @spec revision() :: pos_integer
  def revision, do: @revision

  @doc false
  # call/4 calls `adapter` at `path` with `members`, the call's members after `version`
  # and `time`, in order. `{:ok, body}`, the answer's decoded object, or
  # `{:error, %CallFailure{}}`.
  @spec call(Node.t(), String.t(), [{String.t(), term}], keyword) ::
          {:ok, map} | {:error, CallFailure.t()}
  def call(%Node{kind: :adapter} = adapter, path, members, opts \\ [])
      when is_binary(path) and is_list(members) do
    settings = :apiary |> Application.get_env(__MODULE__, []) |> Keyword.merge(opts)
    started = now()
    deadline = started + Keyword.get(settings, :total, @total)

    result =
      with {:ok, target} <- address(adapter, deadline, settings) do
        attempt(adapter, target, answer_keys(adapter), path, members, nil, deadline, settings)
      end

    case result do
      {:ok, body} -> {:ok, body}
      {:error, cause, details} -> {:error, failure(adapter, path, cause, details, started)}
    end
  end

  # The failure of the call, with its one log line.
  defp failure(adapter, path, cause, details, started) do
    Logger.warning(
      "a call to an adapter failed adapter=#{adapter.public_id} path=#{path} " <>
        "cause=#{cause} duration_ms=#{now() - started}"
    )

    struct!(
      CallFailure,
      Map.merge(details, %{
        adapter_id: adapter.id,
        adapter_public_id: adapter.public_id,
        adapter_name: adapter.name,
        path: path,
        cause: cause
      })
    )
  end

  @doc false
  # run_credential/3 asks `adapter` for a credential for one run (`run-credential`), for
  # `resources`, with `access` (`"read"` or `"write"`) and `purpose`: `"harness"`, under
  # the grant `grant_ref`; or `"work"`, under a grant of the connection `connection_id`
  # (the connection's public id), whose one resource is the ref of the target's
  # collection. `{:ok, %RunCredential{}}`, whose `inspect` shows no token, or
  # `{:error, %CallFailure{}}`.
  @spec run_credential(Node.t(), map, keyword) ::
          {:ok, RunCredential.t()} | {:error, CallFailure.t()}
  def run_credential(adapter, request, opts \\ []) do
    %{resources: resources, access: access, purpose: purpose} = request

    members =
      [
        {"grant_ref", request[:grant_ref]},
        {"connection_id", request[:connection_id]},
        {"resources", resources},
        {"access", to_string(access)},
        {"purpose", to_string(purpose)}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)

    with {:ok, credential} <- typed(adapter, "run-credential", members, opts) do
      {:ok, RunCredential.new(credential)}
    end
  end

  @doc false
  # resolve/3 asks `adapter` which of its grants and resources cover `addresses`
  # (`resolve`). `{:ok, results}`, one for each address, in order: `%{address:,
  # grant_ref:, resource_ref:}`, or `%{address:, covered: false}`; or
  # `{:error, %CallFailure{}}`. Whether the run may use a grant is the caller's to check
  # (`Apiary.Adapters.Grants.live_for_organisation/3`).
  @spec resolve(Node.t(), [String.t()], keyword) :: {:ok, [map]} | {:error, CallFailure.t()}
  def resolve(adapter, addresses, opts \\ []) when is_list(addresses),
    do: typed(adapter, "resolve", [{"addresses", addresses}], opts)

  @doc false
  # read_document/3 asks `adapter` for the document at `path` in the resource
  # `resource_ref`, under the grant `grant_ref`, at the version `at` (`read`).
  # `{:ok, %{resolved_at:, content:, found:}}`, `content` nil where the resource has no
  # document at the path; or `{:error, %CallFailure{}}`.
  @spec read_document(Node.t(), map, keyword) :: {:ok, map} | {:error, CallFailure.t()}
  def read_document(adapter, request, opts \\ []) do
    %{grant_ref: grant_ref, resource_ref: resource_ref, path: path, at: at} = request

    members = [
      {"grant_ref", grant_ref},
      {"resource_ref", resource_ref},
      {"path", path},
      {"at", at}
    ]

    typed(adapter, "read", members, opts)
  end

  # A call whose body its schema allows (`Apiary.Adapters.CallWire.call?/2`), else an
  # `ArgumentError` that shows no value; and its answer, read to its schema, else
  # `:invalid_answer`.
  defp typed(adapter, path, members, opts) do
    body = Map.merge(Map.new(members), %{"version" => 1, "time" => "2026-01-01T00:00:00Z"})

    unless CallWire.call?(path, body),
      do: raise(ArgumentError, "a call to #{path} outside its schema")

    started = now()

    with {:ok, answer} <- call(adapter, path, members, opts) do
      case CallWire.answer(path, answer, Map.new(members)) do
        {:ok, read} -> {:ok, read}
        :error -> {:error, failure(adapter, path, :invalid_answer, %{status: 200}, started)}
      end
    end
  end

  # The address checked and resolved (`Apiary.Adapters.CallAddress.check/2`) within the
  # call's time: the lookup has no time limit of its own, so it runs in a task, and one
  # still running when the call's time ends is `:timeout`.
  defp address(adapter, deadline, settings) do
    task =
      Task.Supervisor.async_nolink(__MODULE__.Supervisor, fn ->
        CallAddress.check(adapter, Keyword.take(settings, [:resolver]))
      end)

    case Task.yield(task, max(deadline - now(), 0)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, target}} -> {:ok, target}
      {:ok, {:error, :unresolved}} -> {:error, :unreachable, %{}}
      {:ok, {:error, cause}} -> {:error, cause, %{}}
      {:exit, _reason} -> {:error, :unreachable, %{}}
      nil -> {:error, :timeout, %{}}
    end
  end

  # The public keys of the adapter's access keys in use, read once per call.
  defp answer_keys(adapter) do
    for %AccessKey{public_key: <<_::binary-size(32)>> = key} <- AccessKeys.active_keys(adapter),
        do: key
  end

  # `previous`, the time of the attempt before, nil for the first. Each attempt takes a
  # later time (`time/2`), so a retry's signature is new too.
  defp attempt(adapter, target, keys, path, members, previous, deadline, settings) do
    # The body has the same size at every time, so a call too large takes no time.
    unsent = body(members, @no_time)

    with :ok <- fits(unsent, settings),
         {:ok, time} <- time(CallClock.key(adapter.id, path, unsent), deadline) do
      body = body(members, time)

      signature =
        signature(SigningKey.current(), adapter.public_id, target.instance_id, path, body)

      outcome =
        target
        |> send_call(adapter.public_id, path, body, signature, deadline, settings)
        |> answer(signature, keys)

      case retry(outcome, previous, deadline, settings) do
        {:retry, wait} ->
          Process.sleep(wait)
          attempt(adapter, target, keys, path, members, time, deadline, settings)

        :final ->
          final(outcome)
      end
    end
  end

  defp fits(body, settings) do
    if byte_size(body) > Keyword.get(settings, :max_call, @max_call),
      do: {:error, :too_large, %{}},
      else: :ok
  end

  # The call's time (`Apiary.Adapters.CallClock.take/3`) under `key`, waited for while it
  # is more than `CallClock.ahead/0` seconds ahead of the clock; `:timeout`, with no time
  # taken, when that wait would end after the call's time.
  defp time(key, deadline) do
    clock = System.os_time(:second)
    left = deadline - now()
    latest = clock + CallClock.ahead() + div(max(left, 0), 1000) - 1

    case CallClock.take(key, clock, latest) do
      {:ok, time} ->
        wait = (time - CallClock.ahead() - clock) * 1000
        if wait > 0, do: Process.sleep(wait)
        {:ok, DateTime.from_unix!(time)}

      :late ->
        {:error, :timeout, %{}}
    end
  end

  @doc false
  # body/2 is a call's body: `version` 1, `time`, `now` in UTC to the second, then
  # `members`, in that order, compact.
  @spec body([{String.t(), term}], DateTime.t()) :: binary
  def body(members, %DateTime{} = now) when is_list(members) do
    time = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Jason.encode!(Jason.OrderedObject.new([{"version", 1}, {"time", time} | members]))
  end

  @doc false
  # signature/5 is a call's `X-Qory-Signature-Ed25519`: the signature under `key` of the
  # call of the adapter `adapter_id` from its instance `instance_id` at `path` with `body`,
  # in base64url without padding.
  @spec signature(SigningKey.t(), String.t(), String.t(), String.t(), binary) :: String.t()
  def signature(key, adapter_id, instance_id, path, body) do
    Ed25519.encode(
      SigningKey.sign(key, SignedMessage.call(adapter_id, instance_id, "POST", path, body))
    )
  end

  @doc false
  # signed?/5 is whether `encoded`, an answer's `X-Qory-Signature-Ed25519`, is the
  # signature under one of `keys` of the answer with `status` and `body` to the call
  # signed `call_signature`: decoded strictly, 64 bytes. An answer with a status outside
  # 100 to 599 is never signed.
  @spec signed?(term, integer, String.t(), binary, [binary]) :: boolean
  def signed?(encoded, status, call_signature, body, keys)
      when is_binary(encoded) and status in 100..599 do
    case Ed25519.decode(encoded, 64) do
      {:ok, raw} ->
        message = SignedMessage.call_answer(status, call_signature, body)
        Enum.any?(keys, &Ed25519.verify(message, raw, &1))

      :error ->
        false
    end
  end

  def signed?(_encoded, _status, _call_signature, _body, _keys), do: false

  # One attempt, within the attempt's time and the call's: `{:answer, status, headers,
  # body}`, `:too_large`, `:unreachable` or `:timeout`.
  defp attempt_setting(settings), do: Keyword.get(settings, :attempt, @attempt)

  defp send_call(target, adapter_public_id, path, body, signature, deadline, settings) do
    budget = min(attempt_setting(settings), deadline - now())

    if budget <= 0 do
      :timeout
    else
      task =
        Task.Supervisor.async_nolink(__MODULE__.Supervisor, fn ->
          request(target, adapter_public_id, path, body, signature, budget, settings)
        end)

      case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
        {:ok, outcome} -> outcome
        {:exit, _reason} -> :unreachable
        nil -> :timeout
      end
    end
  end

  defp request(target, adapter_public_id, path, body, signature, budget, settings) do
    max_answer = Keyword.get(settings, :max_answer, @max_answer)
    uri = URI.parse(target.base <> path)
    host = if uri.port == 443, do: target.host, else: "#{target.host}:#{uri.port}"

    options =
      [
        url: %{uri | host: Address.ntoa(target.address)},
        method: :post,
        headers: [
          {"host", host},
          {"content-type", "application/json"},
          {"user-agent", "qory-apiary"},
          {"x-qory-adapter-id", adapter_public_id},
          {"x-qory-instance-id", target.instance_id},
          {"x-qory-contract-version", Integer.to_string(@revision)},
          {"x-qory-signature-ed25519", signature}
        ],
        body: body,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        raw: true,
        inet6: tuple_size(target.address) == 8,
        receive_timeout: budget,
        # A fixed connect timeout, the attempt's setting: the connect options are part of
        # the key of Finch's pool, so a timeout that changed with each budget would start
        # a pool for each. The attempt's task holds the budget.
        connect_options: [hostname: target.host, timeout: attempt_setting(settings)],
        into: collect(max_answer)
      ]
      |> Keyword.merge(Keyword.get(settings, :req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status} = response} ->
        if Req.Response.get_private(response, :too_large),
          do: :too_large,
          else: {:answer, status, response.headers, response.body || ""}

      {:error, _exception} ->
        :unreachable
    end
  end

  # The answer's body, kept only up to `max_bytes`: a declared length over it, or a body
  # that grows past it, stops the read.
  defp collect(max_bytes) do
    fn {:data, data}, {request, response} ->
      body = if is_binary(response.body), do: response.body, else: ""

      declared =
        with [value | _] <- Req.Response.get_header(response, "content-length"),
             {length, ""} <- Integer.parse(value),
             do: length,
             else: (_ -> nil)

      if (is_integer(declared) and declared > max_bytes) or
           byte_size(body) + byte_size(data) > max_bytes do
        {:halt, {request, Req.Response.put_private(response, :too_large, true)}}
      else
        {:cont, {request, %{response | body: body <> data}}}
      end
    end
  end

  # An attempt's outcome, its signature checked: `{:signed, status, body, headers}`,
  # `{:unsigned, status}`, `:too_large`, `:unreachable` or `:timeout`.
  defp answer({:answer, status, headers, body}, signature, keys) do
    case Map.get(headers, "x-qory-signature-ed25519") do
      [encoded] ->
        if signed?(encoded, status, signature, body, keys),
          do: {:signed, status, body, headers},
          else: {:unsigned, status}

      _none_or_several ->
        {:unsigned, status}
    end
  end

  defp answer(other, _signature, _keys), do: other

  # Whether to try again, and after how long: once, after the first attempt, within the
  # call's time.
  defp retry(outcome, nil = _previous, deadline, settings) do
    wait =
      case outcome do
        failed when failed in [:unreachable, :timeout] -> jitter(settings)
        {:unsigned, status} when status in [502, 503, 504] -> jitter(settings)
        {:signed, 429, _body, headers} -> retry_after(headers)
        _other -> nil
      end

    if is_integer(wait) and now() + wait < deadline, do: {:retry, wait}, else: :final
  end

  defp retry(_outcome, _previous, _deadline, _settings), do: :final

  defp jitter(settings) do
    {min, max} = Keyword.get(settings, :retry_wait, @retry_wait)
    min + :rand.uniform(max - min + 1) - 1
  end

  # `Retry-After` in whole seconds, as milliseconds; nil for another form.
  defp retry_after(headers) do
    with [value] <- Map.get(headers, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(value) do
      seconds * 1000
    else
      _other -> nil
    end
  end

  defp final({:signed, 200, body, _headers}) do
    case Wire.decode(body) do
      {:ok, %{"version" => 1, "revision" => @revision} = decoded} -> {:ok, decoded}
      _other -> {:error, :invalid_answer, %{status: 200}}
    end
  end

  defp final({:signed, status, body, _headers}) do
    case Wire.decode(body) do
      {:ok, %{"error" => code} = refusal}
      when map_size(refusal) == 1 and is_binary(code) and status in 400..599 ->
        if Regex.match?(@refusal_code, code),
          do: {:error, :refused, %{status: status, code: code}},
          else: {:error, :invalid_answer, %{status: status}}

      _other ->
        {:error, :invalid_answer, %{status: status}}
    end
  end

  defp final({:unsigned, 401}), do: {:error, :refused, %{status: 401, code: "unauthorized"}}

  defp final({:unsigned, status}) when status in [502, 503, 504],
    do: {:error, :unreachable, %{status: status}}

  defp final({:unsigned, status}), do: {:error, :invalid_answer, %{status: status}}
  defp final(:too_large), do: {:error, :invalid_answer, %{}}
  defp final(:unreachable), do: {:error, :unreachable, %{}}
  defp final(:timeout), do: {:error, :timeout, %{}}

  defp now, do: System.monotonic_time(:millisecond)

  @doc false
  # The paths of the calls a run makes: its credentials (`run-credential`), its harness
  # sources (`resolve`) and its harness files (`read`).
  @spec paths() :: [String.t()]
  def paths, do: @paths

  @doc false
  # record_failure/3 writes `failure`, a failed call of one of `paths/0`, on the run of
  # the queue `run` through `repo`, inside the caller's transaction where there is one:
  # the adapter, the cause, the call's path, and the refusal's code for `:refused`. The
  # run's page shows them (`ApiaryWeb.WorkItemComponents`). How the run ends is the
  # caller's. `:ok`, or `{:error, :not_found}` for a run that is gone.
  @spec record_failure(module, DispatchRun.t(), CallFailure.t()) :: :ok | {:error, :not_found}
  def record_failure(repo, %DispatchRun{id: id}, %CallFailure{path: path} = failure)
      when path in @paths do
    code = if failure.cause == :refused, do: failure.code

    case repo.update_all(from(d in DispatchRun, where: d.id == ^id),
           set: [
             adapter_failure_id: failure.adapter_id,
             adapter_failure: failure.cause,
             adapter_failure_call: path,
             adapter_failure_code: code,
             updated_at: DateTime.utc_now()
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end
end

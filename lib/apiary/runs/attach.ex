defmodule Apiary.Runs.Attach do
  @moduledoc """
  A run's attach: how the gateway a run key names takes on a run that registered through
  it (`Apiary.Runs.Registration`), and the run configuration it is given then.

  `parse/1` reads the attach's body, decoded: `version`, 1; `run_key`, a string, read by
  `attach/4`; `interval_seconds`, an integer from 1 to 300; `events`, a list of strings
  that are not empty; `forager_version`, a string that is not empty and holds no NUL;
  `contract_version`, an integer from 1; and `time`, a date and time in UTC to the whole
  second, which is a real one. Every member is required, and one the contract does not
  name is refused as `"body"`. A body that breaks a rule is
  `{:error, :invalid_request, detail}`, where `detail` names the member and never repeats
  a value. Whether `time` is within `max_skew_seconds/0` of the server's clock is the
  caller's to ask (`fresh?/2`).

  `attach/4` takes it, for the gateway's access key and the run id of the path. The first
  of these that applies is the answer:

    1. a key that is not a gateway's is `{:error, :not_a_gateway}`;
    2. a run key that does not verify (`Apiary.Runs.RunKey.verify/2`), whose run id is not
       the path's, or that is not the run key the run was given, is
       `{:error, :run_key_invalid}`;
    3. a run whose workspace or organisation is out of use, as every key's is at its
       verification (`Apiary.AccessKeys.place_in_use?/2`), is `{:error, :unauthorized}`,
       and a run whose workspace `Apiary.Access` does not let post (`run.post_events`) is
       `{:error, :not_found}`;
    4. a repeat: the same gateway, under any of its active keys, attaching the same run
       again while the run is live, is given the answer it was given, nothing stored
       again. A repeat is the gateway's and the run's, not the body's bytes, so a gateway
       that restarted, or replaced its key, takes its run on again;
    5. a run that has ended is `{:error, :gone}`: its exit arrived, its starter's outcome
       ended it, it was lost after its attach, or its events were pruned. So is a run
       whose record is gone;
    6. a run never attached whose attach window has closed (`attach_by`) is
       `{:error, :run_key_expired}`;
    7. a run key that names another gateway is `{:error, :wrong_gateway}`;
    8. a gateway that may not serve the run's workspace (`Apiary.Gateways.may_serve?/2`)
       is `{:error, :workspace_not_served}`;
    9. a run another gateway attached is `{:error, :run_attached}`;
    10. a workspace whose run configuration cannot be read is `{:error, :unavailable}`;
    11. else the run is attached: when, the attach's `time`, its heartbeat interval, which
        the run is held to from then on (`Apiary.Runs.Liveness`), Forager's version and the
        contract's, and the digest of the run configuration it is given.

  Since the gateway that attaches is the one the run key names, and a repeat is that
  gateway's, the ninth answer is never reached by a request that passes the seventh; it
  stands so that no order of the checks lets a second gateway take a run on.

  The answer is the run configuration in force for the run's target, read under the
  run's own place (`Apiary.Runs.Sender.place_key/2`), never the gateway's: its bytes, with
  `labels` and `about` of the run's registration added after its last member, each left
  out when the registration had none; and its digest, which is the configuration's, for
  `X-Qory-Run-Configuration` and `ETag`.

  No run is changed on any refusal. Once the run is attached, the gateway's batches,
  heartbeats and reloads are taken for it, and nobody else's (`Apiary.Runs.Sender`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Gateways, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Batch, Registration, Run, RunKey, Sender}

  @version "version"
  @run_key "run_key"
  @interval_seconds "interval_seconds"
  @events "events"
  @forager_version "forager_version"
  @contract_version "contract_version"
  @time "time"
  @members [
    @version,
    @run_key,
    @interval_seconds,
    @events,
    @forager_version,
    @contract_version,
    @time
  ]

  @document_version 1
  @int4 2_147_483_647
  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  # The states of a run that has ended, with the old names an older release stored them
  # under (`Apiary.Runs.Run.old_states/0`).
  @ended Run.with_old_names(~w(completed failed cancelled))

  @typedoc "An attach's body, as `parse/1` read it."
  @type t :: %__MODULE__{
          run_key: String.t(),
          interval_seconds: pos_integer,
          events: [String.t()],
          forager_version: String.t(),
          contract_version: pos_integer,
          time: DateTime.t()
        }

  @enforce_keys [:run_key, :interval_seconds, :events, :forager_version, :contract_version, :time]
  defstruct @enforce_keys

  @typedoc """
  The answer of an attach: the run, whether it repeats an attach, and the run configuration
  it is given (`t:Apiary.Runs.Registration.settings/0`), with `settings` the bytes the
  answer carries, the registration's `labels` and `about` among them.
  """
  @type answer :: %{
          required(:run) => Run.t(),
          required(:repeated) => boolean,
          required(:settings) => binary,
          required(:digest) => String.t(),
          required(:etag) => String.t(),
          required(:managed) => boolean
        }

  @doc "The most seconds an attach's `time` may be from the server's clock."
  def max_skew_seconds, do: Registration.max_skew_seconds()

  @doc "Reads an attach's decoded body: see the moduledoc for the rules."
  @spec parse(term) :: {:ok, t} | {:error, :invalid_request, String.t()}
  def parse(%{} = body) do
    with :ok <- check(Enum.all?(Map.keys(body), &(&1 in @members)), "body"),
         :ok <- check(body[@version] === @document_version, @version),
         :ok <- check(is_binary(body[@run_key]), @run_key),
         {:ok, interval_seconds} <- interval_seconds(body[@interval_seconds]),
         {:ok, events} <- events(body[@events]),
         {:ok, forager_version} <- forager_version(body[@forager_version]),
         {:ok, contract_version} <- contract_version(body[@contract_version]),
         {:ok, time} <- time(body[@time]) do
      {:ok,
       %__MODULE__{
         run_key: body[@run_key],
         interval_seconds: interval_seconds,
         events: events,
         forager_version: forager_version,
         contract_version: contract_version,
         time: time
       }}
    end
  end

  def parse(_body), do: invalid("body")

  @doc "Whether the attach's `time` is within `max_skew_seconds/0` of `now`, either side."
  @spec fresh?(t, DateTime.t()) :: boolean
  def fresh?(%__MODULE__{time: time}, %DateTime{} = now \\ DateTime.utc_now()),
    do: abs(DateTime.diff(time, now, :microsecond)) <= max_skew_seconds() * 1_000_000

  defp check(true, _member), do: :ok
  defp check(_false, member), do: invalid(member)

  defp invalid(detail), do: {:error, :invalid_request, detail}

  defp interval_seconds(value) when is_integer(value) do
    if value in 1..Batch.max_interval_seconds(),
      do: {:ok, value},
      else: invalid(@interval_seconds)
  end

  defp interval_seconds(_value), do: invalid(@interval_seconds)

  defp events(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values},
      else: invalid(@events)
  end

  defp events(_values), do: invalid(@events)

  defp forager_version(value) when is_binary(value) and value != "" do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: invalid(@forager_version)
  end

  defp forager_version(_value), do: invalid(@forager_version)

  defp contract_version(value) when is_integer(value) and value in 1..@int4, do: {:ok, value}
  defp contract_version(_value), do: invalid(@contract_version)

  defp time(value) do
    with true <- is_binary(value) and Regex.match?(@whole_seconds, value),
         {:ok, time} <- Batch.time(value) do
      {:ok, time}
    else
      _ -> invalid(@time)
    end
  end

  @doc """
  Attaches the run `run_id` for the gateway's key (an access key, or its scope), in the
  order the moduledoc gives. `meta` is what the request said beside its body:
  `forager_version`, as its headers named it, nil when they did not. `{:ok, answer}`
  (`t:answer/0`), or `{:error, reason}`.
  """
  @spec attach(AccessKey.t() | Scope.t(), term, t, map) ::
          {:ok, answer}
          | {:error,
             :not_a_gateway
             | :run_key_invalid
             | :unauthorized
             | :not_found
             | :gone
             | :run_key_expired
             | :wrong_gateway
             | :workspace_not_served
             | :run_attached
             | :unavailable}
  def attach(%Scope{access_key: %AccessKey{} = access_key}, run_id, attach, meta),
    do: attach(access_key, run_id, attach, meta)

  def attach(%AccessKey{} = access_key, run_id, %__MODULE__{} = attach, meta) do
    now = DateTime.utc_now()
    access_key = Repo.preload(access_key, [:workspace, :node])

    with :ok <- gateway(access_key),
         {:ok, grant, payload} <- verified(attach.run_key, run_id),
         {:ok, workspace, run} <- held(grant),
         :ok <- given(run, payload),
         :ok <- in_use(run),
         place = Sender.place_key(run, access_key),
         :ok <- may_post(place),
         {:ok, answer} <- store(run.id, access_key, grant, workspace, attach, meta, now) do
      if not answer.repeated, do: attached(access_key, answer.run, now)
      {:ok, answer}
    end
  rescue
    exception ->
      Logger.error("an attach could not be stored: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp gateway(%AccessKey{node: %Node{kind: :gateway}}), do: :ok
  defp gateway(_access_key), do: {:error, :not_a_gateway}

  defp verified(run_key, run_id) do
    case RunKey.verify(run_key) do
      {:ok, %{run_id: ^run_id} = grant, payload} -> {:ok, grant, payload}
      _invalid -> {:error, :run_key_invalid}
    end
  end

  # The run the run key names, in its workspace. One whose record is gone has ended.
  defp held(%{workspace: public_id, run_id: run_id}) do
    with %Workspace{} = workspace <- Repo.get_by(Workspace, public_id: public_id),
         %Run{} = run <-
           Repo.one(from r in Run, where: r.workspace_id == ^workspace.id and r.run_id == ^run_id) do
      {:ok, workspace, run}
    else
      nil -> {:error, :gone}
    end
  end

  # The run key the run was given, byte for byte: a run key this server signed for the same
  # run id, of another run, is not this run's.
  defp given(%Run{run_key_payload: payload}, payload) when is_binary(payload), do: :ok
  defp given(_run, _payload), do: {:error, :run_key_invalid}

  defp in_use(%Run{organisation_id: organisation_id, workspace_id: workspace_id}) do
    if AccessKeys.place_in_use?(organisation_id, workspace_id),
      do: :ok,
      else: {:error, :unauthorized}
  end

  # The run's workspace may be posted to: what can refuse it is a feature that is off.
  defp may_post(place) do
    scope = Scope.for_access_key(place)

    case Access.authorize(scope, :"run.post_events", scope.workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # Under the run's projection lock and its row's, as an outcome is stored, so two attaches
  # of one run take turns and a pass never writes over the attach.
  defp store(id, access_key, grant, workspace, attach, meta, now) do
    Repo.transact(fn ->
      Runs.Projector.lock(id)
      run = Repo.one!(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")
      gateway = access_key.node

      cond do
        repeat?(run, gateway) ->
          repeat(access_key, run)

        ended?(run) ->
          {:error, :gone}

        is_nil(run.attached_at) and DateTime.compare(now, run.attach_by) == :gt ->
          {:error, :run_key_expired}

        grant.gateway != gateway.public_id or run.gateway_id != gateway.id ->
          {:error, :wrong_gateway}

        not Gateways.may_serve?(gateway, workspace) ->
          {:error, :workspace_not_served}

        not is_nil(run.attached_at) ->
          {:error, :run_attached}

        true ->
          take(access_key, run, attach, meta, now)
      end
    end)
  end

  # The gateway that attached the run, under any of its keys, while the run is live.
  defp repeat?(%Run{attached_at: %DateTime{}, gateway_id: id} = run, %Node{id: id}),
    do: not ended?(run)

  defp repeat?(_run, _gateway), do: false

  # Its exit arrived, its starter's outcome ended it, or it was lost after its attach; or
  # retention pruned its events, and the workspace wants nothing more of it.
  defp ended?(%Run{} = run) do
    run.state in @ended or not is_nil(run.exited_at) or not is_nil(run.outcome_state) or
      not is_nil(run.events_pruned_at) or (run.state == "lost" and not is_nil(run.attached_at))
  end

  defp repeat(access_key, run) do
    with {:ok, settings} <-
           Registration.answered(Sender.place_key(run, access_key), run, run.attach_answer_digest),
         do: {:ok, answer(run, settings, true)}
  end

  defp take(access_key, run, attach, meta, now) do
    with {:ok, settings} <-
           Registration.configuration(Sender.place_key(run, access_key), run.registration_labels) do
      run =
        run
        |> Ecto.Changeset.change(
          attached_at: now,
          attach_time: attach.time,
          attach_interval_seconds: attach.interval_seconds,
          attach_answer_digest: settings.digest,
          forager_version: kept_version(meta[:forager_version] || attach.forager_version),
          contract_version: attach.contract_version,
          updated_at: now
        )
        |> Repo.update!()

      {:ok, answer(run, settings, false)}
    end
  end

  # As the fold keeps Forager's version: at most 255 bytes, cut on a character boundary.
  defp kept_version(version) when byte_size(version) <= 255, do: version

  defp kept_version(version),
    do: version |> binary_part(0, 255) |> String.chunk(:valid) |> List.first("")

  # The run configuration's bytes, with the registration's labels and `about` after its
  # last member, each only when the registration had some; its digest stays the
  # configuration's.
  defp answer(run, %{settings: document} = settings, repeated) do
    members =
      [{"labels", run.registration_labels}, {"about", run.registration_about}]
      |> Enum.reject(fn {_name, value} -> value in [nil, %{}] end)
      |> Enum.map(fn {name, value} -> [?,, Jason.encode!(name), ?:, Jason.encode!(value)] end)

    body =
      case members do
        [] -> document
        members -> with_members(document, members)
      end

    Map.merge(settings, %{settings: body, run: run, repeated: repeated})
  end

  # A document is one JSON object: its members end before its last `}`.
  defp with_members(document, members) do
    trimmed = String.trim_trailing(document)
    size = byte_size(trimmed) - 1
    <<head::binary-size(^size), "}">> = trimmed
    members = if String.trim(head) == "{", do: tl(List.flatten(members)), else: members
    IO.iodata_to_binary([head, members, "}"])
  end

  # Bookkeeping after the commit: it never fails the attach.
  defp attached(access_key, run, now) do
    AccessKeys.touch_delivery(access_key, %{last_used_at: now})
    Runs.broadcast_changed(run)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end

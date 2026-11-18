defmodule Apiary.ModelKeys.Report do
  @moduledoc """
  A gateway's report of the states of a run's model keys, `POST /v1/runs/<run_id>/model-keys`
  of the Forager contract, and its answer: the newest state of each key of the run, from
  every gateway (`ApiaryWeb.Contract.ModelKeysController`).

  `parse/3` reads the body, as the contract's `model-keys-report.schema.json` has it:
  `version`, 1; `run_id`, the run id of the path; `time`, an RFC 3339 time in UTC to the
  whole second, `2026-11-10T12:00:05Z`; `session`, optional, an integer of 1 or more, the number of the session the key states
  were observed in, which the key windows of that session's record take
  (`Apiary.Runs.Sessions`); and `keys`, at most 66, each item a key's state in
  one window (`credential`, `window`, `status`, `resets_at`, `utilization`,
  `cooldown_until`, `source` and `observed_at`), with `cooldown_until` when the status is
  `rejected` and without it otherwise. A `resets_at` or a `cooldown_until` more than
  `max_reset_days/0` days after the item's `observed_at` is taken as that bound: the
  contract's README bounds a window's reset at 31 days after the provider's response
  arrived, and a cooldown ends at a reset. A member the schema does not define, a member
  twice, and a value of the wrong form are
  `{:error, :invalid_request, name}`, where `name` is the member and never a value. An
  `observed_at` more than `max_skew_seconds/0` after the server's clock is refused as
  `observed_at`, as the contract's README has it: such a row would stay newer than every later report. Whether `time`
  is within `max_skew_seconds/0` of the server's clock is the caller's to ask
  (`fresh?/2`).

  `answer/5` takes the report for the run, in order:

    1. `{:error, :not_found}` unless model keys apply: the `factory` and `secrets`
       features on among the ones the run kept when it was claimed, until it has ended
       and for 60 seconds after (`recorded/3`), or the instance's for a run that ended
       before that or kept none;
    2. `{:error, :not_found}` for a run the key's gateway does not hold, as a gateway's
       secrets request finds it: a run through the key's gateway, whose run key lists the
       key, that the key and the request's instance may reload, of a workspace the
       gateway may still serve; then where `Apiary.Access` refuses the key
       `run.post_events` on the run;
    3. `{:error, :gone}` for a run that has ended (`Apiary.Runs.Sender.live?/2`): not
       pending or running, unless it is lost after its attach and not lost for good, or
       with its exit or its events pruned; the states are recorded first, as in
       step 4, when the run ended at most 60 seconds before, by this server's clock: the
       first of when this server received the run's first `dev.qory.run.exited` or
       `dev.qory.run.refused`, and when it ended the run by another path: for a lost
       run, when it became lost for good, as the lost-run check ended it for its silence
       (`silenced_at`) or at its backstop (`backstop_at`). The gateway sends its last
       report within 10 seconds of the run's end;
    4. else the states are recorded (`Apiary.ModelKeys.record/4`), through the run's keys
       alone (`Apiary.ModelKeys.run_keys/1`): an item of a credential the run does not
       have, and an item of a window outside the contract's list
       (`Apiary.ModelKeys.State.windows/0`), is left out, and the report is taken all the
       same. `{:ok, body}`, the answer `{"version":1,"keys":[…]}` with the
       newest state of each key of the run and window, under the run's credential names.
       A report with a `session` also counts the utilization of its items into that
       session's key windows, in step 4 and in the last of step 3, and a report with none
       leaves every session's windows as they are.

  No key value is read or written here, and a log line has no part of the body.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Access, ModelKeys, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.ModelKeys.State
  alias Apiary.Runs.{Batch, Event, ProviderCredential, Registration, Run, RunKey, Sender}

  @required ~w(version run_id time keys)
  @members @required ++ ~w(session)
  @required_item ~w(credential window status source observed_at)
  @item_members @required_item ++ ~w(resets_at utilization cooldown_until)
  @credential ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/
  @max_skew_seconds 300
  # The gateway sends its last report within 10 s of the run's end, sometimes before its
  # `dev.qory.run.exited`: a report this long after the run's end is still stored.
  @after_exit_seconds 60
  # The contract's bound on `resets_at`: at most 31 days after the provider's response
  # arrived.
  @max_reset_days 31
  # 6 keys of a run, 11 windows each (`Apiary.ModelKeys.State.windows/0`).
  @max_keys 66
  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc "A report as `parse/3` read it."
  @type t :: %{time: DateTime.t(), keys: [map], session: pos_integer | nil}

  @doc "The most seconds a report's `time` may be from the server's clock."
  @spec max_skew_seconds() :: pos_integer
  def max_skew_seconds, do: @max_skew_seconds

  @doc "The most days a stored `resets_at` or `cooldown_until` is after its `observed_at`."
  @spec max_reset_days() :: pos_integer
  def max_reset_days, do: @max_reset_days

  @doc """
  Reads the report in `raw_body` for the run `run_id` of the path, at `now`:
  `{:ok, report}` or `{:error, :invalid_request, name}`.
  """
  @spec parse(binary, String.t(), DateTime.t()) ::
          {:ok, t} | {:error, :invalid_request, String.t()}
  def parse(raw_body, run_id, %DateTime{} = now) when is_binary(raw_body) do
    with {:ok, body} <- decode(raw_body),
         {:ok, fields} <- object(body, @required, @members, "body"),
         :ok <- check(fields["version"] === 1, "version"),
         :ok <- check(fields["run_id"] === run_id and Batch.uuid?(run_id), "run_id"),
         :ok <- check(whole_seconds?(fields["time"]), "time"),
         :ok <- check(session?(fields), "session"),
         {:ok, time} <- time(fields["time"], "time"),
         {:ok, keys} <- keys(fields["keys"], now) do
      {:ok, %{time: time, keys: keys, session: fields["session"]}}
    end
  end

  @doc "Whether the report's `time` is within `max_skew_seconds/0` of `now`, either side."
  @spec fresh?(t, DateTime.t()) :: boolean
  def fresh?(%{time: time}, %DateTime{} = now),
    do: abs(DateTime.diff(time, now, :microsecond)) <= @max_skew_seconds * 1_000_000

  # `session`, the number of the session open when the gateway made the report, is
  # optional: an integer of 1 or more.
  defp session?(%{"session" => session}), do: is_integer(session) and session >= 1
  defp session?(_fields), do: true

  defp decode(raw_body) do
    case Jason.decode(raw_body, objects: :ordered_objects) do
      {:ok, body} -> {:ok, body}
      {:error, _reason} -> invalid("body")
    end
  end

  # The members of a JSON object, each once, all of `required` among them and none
  # outside `allowed`: a map, or the refusal `name`.
  defp object(%Jason.OrderedObject{values: values}, required, allowed, name) do
    names = Enum.map(values, &elem(&1, 0))

    if Enum.uniq(names) == names and Enum.all?(names, &(&1 in allowed)) and
         Enum.all?(required, &(&1 in names)),
       do: {:ok, Map.new(values)},
       else: invalid(name)
  end

  defp object(_value, _required, _allowed, name), do: invalid(name)

  defp keys(items, now) when is_list(items) and length(items) <= @max_keys do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case item(item, now) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      refusal -> refusal
    end
  end

  defp keys(_items, _now), do: invalid("keys")

  defp item(item, now) do
    with {:ok, fields} <- object(item, @required_item, @item_members, "keys"),
         :ok <- check(credential?(fields["credential"]), "keys.credential"),
         :ok <- check(State.window?(fields["window"]), "keys.window"),
         :ok <- check(fields["status"] in State.statuses(), "keys.status"),
         :ok <- check(fields["source"] in State.sources(), "keys.source"),
         :ok <- check(utilization?(fields["utilization"]), "keys.utilization"),
         {:ok, resets_at} <- optional_time(fields["resets_at"], "keys.resets_at"),
         {:ok, cooldown_until} <- optional_time(fields["cooldown_until"], "keys.cooldown_until"),
         :ok <-
           check(cooldown_fits?(fields["status"], cooldown_until), "keys.cooldown_until"),
         {:ok, observed_at} <- time(fields["observed_at"], "keys.observed_at"),
         :ok <- check(not later?(observed_at, now), "observed_at") do
      {:ok,
       %{
         credential: fields["credential"],
         window: fields["window"],
         status: fields["status"],
         resets_at: bound(resets_at, observed_at),
         utilization: fields["utilization"],
         cooldown_until: bound(cooldown_until, observed_at),
         source: fields["source"],
         observed_at: observed_at
       }}
    end
  end

  # A cooldown with a rejected window, and with no other.
  defp cooldown_fits?("rejected", cooldown_until), do: not is_nil(cooldown_until)
  defp cooldown_fits?(_status, cooldown_until), do: is_nil(cooldown_until)

  defp whole_seconds?(time), do: is_binary(time) and Regex.match?(@whole_seconds, time)

  defp credential?(name), do: is_binary(name) and Regex.match?(@credential, name)

  defp utilization?(nil), do: true
  defp utilization?(value), do: is_integer(value) and value in 0..100

  defp optional_time(nil, _name), do: {:ok, nil}
  defp optional_time(value, name), do: time(value, name)

  defp time(value, name) do
    case Batch.time(value) do
      {:ok, time} -> {:ok, time}
      :error -> invalid(name)
    end
  end

  # A time held to at most `@max_reset_days` days after `observed_at`.
  defp bound(nil, _observed_at), do: nil

  defp bound(time, observed_at) do
    limit = DateTime.add(observed_at, @max_reset_days * 86_400, :second)
    if DateTime.compare(time, limit) == :gt, do: limit, else: time
  end

  defp later?(time, now),
    do: DateTime.diff(time, now, :microsecond) > @max_skew_seconds * 1_000_000

  defp check(true, _name), do: :ok
  defp check(_false, name), do: invalid(name)

  defp invalid(name), do: {:error, :invalid_request, name}

  @doc """
  Takes `report` for the run `run_id`, from `access_key` and the instance `instance_id`,
  at `now`, in the order of the moduledoc: `{:ok, body}`, or `{:error, reason}` with
  `:not_found`, `:gone` or `:unavailable`.
  """
  @spec answer(AccessKey.t(), String.t(), t, String.t() | nil, DateTime.t()) ::
          {:ok, binary} | {:error, :not_found | :gone | :unavailable}
  def answer(%AccessKey{} = access_key, run_id, report, instance_id, %DateTime{} = now) do
    access_key = Repo.preload(access_key, [:workspace, :node])

    with {:ok, run} <- run(access_key, run_id, instance_id),
         features = window_features(run, now),
         true <- ProviderCredential.applies?(features) || {:error, :not_found},
         :ok <- may_post(access_key, run) do
      cond do
        Sender.live?(run, now) ->
          keys = ModelKeys.run_keys(run, features)
          :ok = ModelKeys.record(keys, report.keys, now, session(run, report))
          {:ok, body(ModelKeys.run_states(keys, now))}

        just_ended?(run, now) ->
          :ok =
            ModelKeys.record(
              ModelKeys.run_keys(run, features),
              report.keys,
              now,
              session(run, report)
            )

          {:error, :gone}

        true ->
          {:error, :gone}
      end
    end
  rescue
    exception ->
      Logger.error("a model keys report could not be taken: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  # The session a report names, for the key windows of its record: nil for a report with no
  # `session`, which changes no session's record.
  defp session(_run, %{session: nil}), do: nil
  defp session(run, %{session: number}), do: {run, number}

  @doc """
  recorded/3 is the names of the features a report for the run `run_id` from
  `access_key` is checked against at `now`, as `answer/5` checks them: the ones the run
  kept when it was claimed, until it has ended and for 60 seconds after, the window in
  which its last report is still recorded; nil for a run the key does not find, a run
  that ended before that, or a run that kept none, which follow the instance's features.
  """
  @spec recorded(AccessKey.t(), term, DateTime.t()) :: [String.t()] | nil
  def recorded(%AccessKey{} = access_key, run_id, %DateTime{} = now) do
    with true <- Batch.uuid?(run_id),
         %Run{} = run <- Repo.one(Sender.run_query(access_key, run_id)) do
      window_features(run, now)
    else
      _other -> nil
    end
  end

  # The features the run kept, until it has ended and while its end is within
  # `@after_exit_seconds`; else nil.
  defp window_features(%Run{} = run, now) do
    if not Run.ended?(run, now) or just_ended?(run, now), do: run.features
  end

  # The run as a secrets request finds it: every other run is not found, whatever the
  # cause.
  defp run(access_key, run_id, instance_id) do
    with true <- Batch.uuid?(run_id),
         %Run{} = run <- Repo.one(Sender.run_query(access_key, run_id)),
         true <- held?(access_key, run, instance_id) do
      {:ok, run}
    else
      _other -> {:error, :not_found}
    end
  end

  defp held?(access_key, run, instance_id) do
    Run.through_gateway?(run) and
      RunKey.lists_key?(run.run_key_payload, access_key.public_key) and
      Registration.reload_allowed?(access_key, run, instance_id) and
      Sender.serves?(run, access_key)
  end

  defp may_post(access_key, run) do
    case Access.check(Scope.for_access_key(access_key), :"run.post_events", run) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # Whether the run ended at most `@after_exit_seconds` before `now`, by this server's
  # clock alone: the run ended at the first of the times this server recorded for its
  # end (`ended_at/1`). Each is the first of its kind, so no later event reopens the
  # window.
  defp just_ended?(%Run{} = run, now) do
    since = DateTime.add(now, -@after_exit_seconds, :second)

    case ended_at(run, now) do
      nil -> false
      at -> DateTime.compare(at, since) != :lt
    end
  end

  # The first of: when this server received the run's first `dev.qory.run.exited` or
  # `dev.qory.run.refused` (`received_at`; the times the gateway gives those events are
  # not read); when a lost run with no exit became lost for good (`lost_end/2`); when its
  # start failed (`start_failed_at`); and when the starter's outcome came
  # (`outcome_received_at`). Nil for none.
  defp ended_at(%Run{id: id} = run, now) do
    received =
      Repo.one(
        from e in Event,
          where: e.run_id == ^id and e.type in ["dev.qory.run.exited", "dev.qory.run.refused"],
          select: min(e.received_at)
      )

    lost_end = if is_nil(run.exited_at), do: lost_end(run, now)

    [received, lost_end, run.start_failed_at, run.outcome_received_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # When a lost run became lost for good (`Apiary.Runs.Run.lost_for_good?/2`): when the
  # lost-run check ended it for its silence (`silenced_at`); else its `backstop_at`, once
  # `now` is past it; else when it was found lost (`lost_at`), as a run never attached is
  # at the end of its attach window. Until then the run is live and its report recorded.
  # An exit with the state lost sets `lost_at` to the exit's time, and the exit is read
  # from its event instead.
  defp lost_end(%Run{silenced_at: %DateTime{} = at}, _now), do: at

  defp lost_end(%Run{} = run, now) do
    if Apiary.Runs.Liveness.past_backstop?(run, now), do: run.backstop_at, else: run.lost_at
  end

  @doc """
  The body of the answer for `states` (`Apiary.ModelKeys.run_states/2`):
  `{"version":1,"keys":[…]}`, each item a `key_state` of the contract, its members in the
  schema's order, the absent ones left out.
  """
  @spec body([{String.t(), State.t()}]) :: binary
  def body(states) do
    Jason.encode!(
      Jason.OrderedObject.new(
        version: 1,
        keys: Enum.map(states, fn {name, state} -> key_state(name, state) end)
      )
    )
  end

  defp key_state(name, %State{} = state) do
    [
      credential: name,
      window: state.window,
      status: state.status,
      resets_at: wire_time(state.resets_at),
      utilization: state.utilization,
      cooldown_until: wire_time(state.cooldown_until),
      source: state.source,
      observed_at: wire_time(state.observed_at)
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
  end

  # An RFC 3339 time in UTC, to the whole second when it has no fraction.
  defp wire_time(nil), do: nil

  defp wire_time(%DateTime{microsecond: {0, _}} = time),
    do: time |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp wire_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
end

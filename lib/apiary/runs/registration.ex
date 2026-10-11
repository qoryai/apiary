defmodule Apiary.Runs.Registration do
  @moduledoc """
  A run's registration: how a run starts on the server, and the run configuration it is
  given then and on a reload.

  `parse/1` reads the registration's body, decoded, in one of two shapes. Both have
  `version`, `run_id` and `time`, required, and `labels` and `about`, which may be left
  out. The **direct** shape adds the four members the run announces, `forager_version`,
  `contract_version`, `interval_seconds` and `events`, all required. The shape **through a
  gateway** has none of the four, which the gateway sends when it attaches the run
  (`Apiary.Runs.Attach`), and may ask for an attach window, `attach_seconds`. A body with
  any of the four is read as the direct shape, so it needs all four and no
  `attach_seconds`. Every name of the body is read here and nowhere else. A body that breaks a rule is
  `{:error, :invalid_request, detail}`, where `detail` names the member and never repeats
  a value; a member the contract does not name is refused as `"body"`:

    * `version` is 1;
    * `run_id` is a UUID as the contract writes one (`Apiary.Runs.Batch.uuid?/1`);
    * `labels`, when sent, is an object of at most 16 labels, each key 1 to 64 of `a-z`,
      `0-9`, `_`, `.` and `-`, each value a string of at most 256 bytes of UTF-8 with no
      NUL, which nothing could store; left out, the run has none;
    * `about`, when sent, keeps every rule of `about` (`Apiary.Runs.About.validate/1`);
      left out, it says nothing;
    * `time` is a date and time in UTC to the whole second, `2026-10-10T12:00:00Z`, which
      is a real one (`Apiary.Runs.Batch.time/1`); whether it is within
      `max_skew_seconds/0` of the server's clock is the caller's to ask (`fresh?/2`);
    * `forager_version` is a string that is not empty and holds no NUL, `contract_version`
      an integer from 1, `interval_seconds` an integer from 1 to 300, and `events` a list
      of strings that are not empty;
    * `attach_seconds`, in the shape through a gateway alone, is an integer from 1, which
      `attach_window/1` bounds.

  The labels never name anything but the run's target, by the workspace's domain
  (`Apiary.Lingo.Domain`); `about` never selects a policy. `interval_seconds` is kept on
  the run, which is held to it, its heartbeats' interval notwithstanding
  (`Apiary.Runs.Liveness`).

  `register/3` stores the run. A key `Apiary.Access` does not let post (`run.post_events`)
  is `{:error, :not_found}`. Then, when several answers apply, the first of these is given:

    1. a repeat: a run of this id that registered with the same bytes, under any active
       key of the node or node pool that registered it (`Apiary.Runs.Sender`), so a key
       replaced while the run waits is answered too, is given the answer it was given
       (`registration_answer_digest`, or the same run key), nothing stored or admitted
       again. Once that configuration is no longer stored (its target was deleted), the
       repeat is given the configuration in force now for its labels;
    2. a run of this id whose events retention has pruned is `{:error, :gone}`;
    3. where the run goes, by the key's node's choice of gateway as it resolves now
       (`Apiary.Gateways.resolve/1`), never by the body: a gateway's own key is
       `{:error, :gateway_key}`; the shape through a gateway from a node that goes
       directly is `{:error, :node_is_direct}`, and the direct shape from a node whose
       choice is not direct `{:error, :node_uses_gateway}`; a choice that leads nowhere is
       `{:error, :no_default_gateway}`, `{:error, :gateway_not_serving}` or
       `{:error, :gateway_without_key}`;
    4. an instance beyond its node's limit (`Apiary.Nodes.admit/4`) is
       `{:error, :instance_limit}`, the refusal counted on the node;
    5. any other run of this id, registered with other bytes or by another node, or
       created by its events without a registration, is `{:error, :run_id_used}`;
    6. a managed workspace whose run configuration cannot be read
       (`Apiary.Policy.Serving.fetch/2`), or a run key that cannot be made for the
       gateway's address, is `{:error, :unavailable}`: never a run without its policy;
    7. else the run is created, `pending`, under the key, on its node and the instance the
       request claimed (`Apiary.Nodes.placement/2`), with its registration, in the
       transaction of the instance limit; a run through a gateway with the gateway, its
       run key's payload, when it was made and the end of its attach window.

  No run is stored on any refusal. Once the run is stored, the key's use is recorded and
  the run is broadcast as changed. A later event of the run is stored on the same row
  (`Apiary.Runs.Ingest`), and its `run.started` moves it to `running`; the projector never
  writes the registration's fields.

  The answer to a direct registration is the run configuration in force for the target
  the labels name: for a managed workspace the stored bytes and their digest, exactly what
  `Apiary.Policy.Serving.fetch/2` reads; for a workspace that serves none, the document of
  no policy (`Apiary.Policy.Render.no_policy_document/0`) and its digest. The digest is
  kept on the run, so a repeat is given the same answer. The answer to a registration
  through a gateway is the run key (`Apiary.Runs.RunKey`), which names the gateway, with
  its active keys, at most two, and the attach window granted; the run configuration is
  given to the gateway at the attach, never to the node that registered the run.

  `fetch/2` is the reload: the run configuration in force for a run, read by its
  registration's labels, for the active keys of the node that registered it alone, or of
  the gateway that attached it for a run through a gateway (`Apiary.Runs.Sender`).

  The run keeps its registration's `time` (`registration_time`), on the gateway's clock,
  from which the fold takes the clock offset of a run a gateway opened
  (`Apiary.Runs.Fold`), and is projected from sequence 1, which its registration stands
  for (`Apiary.Runs.Run.projected_from/1`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Gateways, Nodes, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Policy.{Render, RunConfiguration, Serving}
  alias Apiary.Runs.{About, Batch, Run, RunKey, Sender}

  # The body's members, by the names the contract gives them.
  @version "version"
  @run_id "run_id"
  @labels "labels"
  @about "about"
  @time "time"
  @forager_version "forager_version"
  @contract_version "contract_version"
  @interval_seconds "interval_seconds"
  @events "events"
  @attach_seconds "attach_seconds"
  # The members of the direct shape alone, which a registration through a gateway leaves
  # to the attach.
  @direct [@forager_version, @contract_version, @interval_seconds, @events]
  @members [@version, @run_id, @labels, @about, @time, @attach_seconds | @direct]

  @document_version 1
  @max_labels 16
  @label_key ~r/\A[a-z0-9_.-]{1,64}\z/
  @label_value 256
  @int4 2_147_483_647
  @max_skew_seconds 300
  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc """
  A registration's body, as `parse/1` read it: its `shape`, `:direct` or `:gateway`; the
  four members of the direct shape, nil in the gateway shape; and the attach window the
  gateway shape asked for, `attach_seconds`, nil when it asked for none.
  """
  @type t :: %__MODULE__{
          shape: :direct | :gateway,
          run_id: Ecto.UUID.t(),
          labels: %{optional(String.t()) => String.t()},
          about: map,
          time: DateTime.t(),
          forager_version: String.t() | nil,
          contract_version: pos_integer | nil,
          interval_seconds: pos_integer | nil,
          events: [String.t()] | nil,
          attach_seconds: pos_integer | nil
        }

  @enforce_keys [:run_id, :labels, :about, :time]
  defstruct [
    :run_id,
    :labels,
    :about,
    :time,
    :forager_version,
    :contract_version,
    :interval_seconds,
    :events,
    :attach_seconds,
    shape: :direct
  ]

  @typedoc """
  What the request said beside its body: `body`, its exact bytes, whose SHA-256 tells a
  repeat from another registration; `contract_version`, the revision of
  `X-Qory-Contract-Version`, which the endpoint has checked; `instance_id`, the instance
  the request claimed, as it verified it; `forager_version`, as the request's headers
  named it, nil when they did not.
  """
  @type meta :: %{
          required(:body) => binary,
          required(:contract_version) => pos_integer,
          optional(:instance_id) => String.t() | nil,
          optional(:forager_version) => String.t() | nil
        }

  @typedoc """
  The run configuration a run is given: `settings`, the document's bytes; `digest`, theirs
  (`Apiary.Policy.Render.digest/1`), for `X-Qory-Run-Configuration`; `etag`, the same
  string quoted, for `ETag`; `managed`, whether the workspace serves a run configuration of
  its own.
  """
  @type settings :: %{settings: binary, digest: String.t(), etag: String.t(), managed: boolean}

  @doc "The most seconds a registration's `time` may be from the server's clock."
  def max_skew_seconds, do: @max_skew_seconds

  @doc "Reads a registration's decoded body: see the moduledoc for the rules."
  @spec parse(term) :: {:ok, t} | {:error, :invalid_request, String.t()}
  def parse(%{} = body) do
    with :ok <- check(Enum.all?(Map.keys(body), &(&1 in @members)), "body"),
         :ok <- check(body[@version] == @document_version, @version),
         {:ok, run_id} <- run_id(body[@run_id]),
         {:ok, labels} <- labels(body),
         {:ok, about} <- about(body),
         {:ok, time} <- time(body[@time]) do
      registration = %__MODULE__{run_id: run_id, labels: labels, about: about, time: time}

      # The shape is the holder's: any member of the direct shape makes it the direct one.
      if Enum.any?(@direct, &Map.has_key?(body, &1)),
        do: direct(registration, body),
        else: through_gateway(registration, body)
    end
  end

  def parse(_body), do: invalid("body")

  defp direct(registration, body) do
    with {:ok, forager_version} <- forager_version(body[@forager_version]),
         {:ok, contract_version} <- contract_version(body[@contract_version]),
         {:ok, interval_seconds} <- interval_seconds(body[@interval_seconds]),
         {:ok, events} <- events(body[@events]),
         :ok <- check(not Map.has_key?(body, @attach_seconds), @attach_seconds) do
      {:ok,
       %{
         registration
         | forager_version: forager_version,
           contract_version: contract_version,
           interval_seconds: interval_seconds,
           events: events
       }}
    end
  end

  defp through_gateway(registration, body) do
    case body do
      %{@attach_seconds => seconds} when is_integer(seconds) and seconds >= 1 ->
        {:ok, %{registration | shape: :gateway, attach_seconds: seconds}}

      %{@attach_seconds => _seconds} ->
        invalid(@attach_seconds)

      _without ->
        {:ok, %{registration | shape: :gateway}}
    end
  end

  @doc """
  The attach window a registration through a gateway is granted, in seconds, for the
  window it asked for (nil for none): the default, `attach_seconds` of
  `config :apiary, Apiary.Runs.Registration` (600 unless set), when it asked for none;
  the ceiling, `max_attach_seconds` (3600 unless set), when it asked for more; what it
  asked for otherwise.
  """
  @spec attach_window(pos_integer | nil) :: pos_integer
  def attach_window(requested) do
    config = Application.get_env(:apiary, __MODULE__, [])
    ceiling = Keyword.get(config, :max_attach_seconds, 3600)

    case requested do
      nil -> min(Keyword.get(config, :attach_seconds, 600), ceiling)
      seconds when is_integer(seconds) -> min(seconds, ceiling)
    end
  end

  @doc """
  Whether the registration's `time` is within `max_skew_seconds/0` of `now`, either side.
  """
  @spec fresh?(t, DateTime.t()) :: boolean
  def fresh?(%__MODULE__{time: time}, %DateTime{} = now \\ DateTime.utc_now()),
    do: abs(DateTime.diff(time, now, :microsecond)) <= @max_skew_seconds * 1_000_000

  defp check(true, _member), do: :ok
  defp check(_false, member), do: invalid(member)

  defp invalid(detail), do: {:error, :invalid_request, detail}

  defp run_id(value),
    do: if(Batch.uuid?(value), do: {:ok, value}, else: invalid(@run_id))

  defp labels(%{@labels => %{} = labels}) when map_size(labels) <= @max_labels do
    valid? =
      Enum.all?(labels, fn {key, value} ->
        Regex.match?(@label_key, key) and is_binary(value) and
          byte_size(value) <= @label_value and storable?(value)
      end)

    if valid?, do: {:ok, labels}, else: invalid(@labels)
  end

  defp labels(%{@labels => _labels}), do: invalid(@labels)
  defp labels(_body), do: {:ok, %{}}

  # Valid UTF-8 with no NUL: Postgres holds none in text or in jsonb.
  defp storable?(value), do: String.valid?(value) and not String.contains?(value, <<0>>)

  # Absent, it says nothing, as an empty `about` does.
  defp about(%{@about => about}) do
    case About.validate(about) do
      :ok -> {:ok, about}
      {:error, detail} -> invalid(detail)
    end
  end

  defp about(_body), do: {:ok, %{}}

  defp time(value) do
    with true <- is_binary(value) and Regex.match?(@whole_seconds, value),
         {:ok, time} <- Batch.time(value) do
      {:ok, time}
    else
      _ -> invalid(@time)
    end
  end

  defp forager_version(value) when is_binary(value) and value != "" do
    if storable?(value), do: {:ok, value}, else: invalid(@forager_version)
  end

  defp forager_version(_value), do: invalid(@forager_version)

  defp contract_version(value) when is_integer(value) and value in 1..@int4, do: {:ok, value}
  defp contract_version(_value), do: invalid(@contract_version)

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

  @doc """
  Registers the run of `registration` for the key (an access key, or its scope), in the
  order the moduledoc gives. `{:ok, answer}` with `run`, the run's row, `repeated`, whether
  it had registered with the same bytes under a key of the same node before, and the run
  configuration it is given (`t:settings/0`). `{:error, reason}` with `:not_found`,
  `:gone`, `:instance_limit`, `:run_id_used` or `:unavailable`.
  """
  @spec register(AccessKey.t() | Scope.t(), t, meta) ::
          {:ok,
           %{required(:run) => Run.t(), required(:repeated) => boolean, optional(atom) => term}}
          | {:error, :not_found | :gone | :instance_limit | :run_id_used | :unavailable}
  def register(%Scope{access_key: %AccessKey{} = access_key}, registration, meta),
    do: register(access_key, registration, meta)

  def register(
        %AccessKey{} = access_key,
        %__MODULE__{} = registration,
        %{body: body, contract_version: _} = meta
      )
      when is_binary(body) do
    now = DateTime.utc_now()
    digest = :crypto.hash(:sha256, body)
    # A verified key carries its workspace and node; one that does not is given them here.
    access_key = Repo.preload(access_key, [:workspace, :node])

    with :ok <- may_post(Scope.for_access_key(access_key)),
         {:ok, held} <- held(access_key, registration, digest) do
      case held do
        {:repeat, run} ->
          repeat(access_key, run)

        held ->
          with {:ok, route} <- route(access_key.node, registration),
               do: admit(held, route, access_key, registration, meta, digest, now)
      end
    end
  end

  # Where the run goes, by the node's recorded choice as it resolves now
  # (`Apiary.Gateways.resolve/1`), never by the body: the resolution's refusals, in the
  # contract's order. A gateway's own key registers no run; then the body's shape against
  # the choice; then a choice that leads nowhere. The gateway's active keys are read here,
  # for the run key.
  defp route(nil, %__MODULE__{shape: :direct}), do: {:ok, :direct}
  defp route(nil, %__MODULE__{shape: :gateway}), do: {:error, :node_is_direct}

  defp route(%Nodes.Node{} = node, %__MODULE__{shape: shape}) do
    cond do
      node.kind == :gateway -> {:error, :gateway_key}
      node.gateway_choice == :direct and shape == :gateway -> {:error, :node_is_direct}
      node.gateway_choice != :direct and shape == :direct -> {:error, :node_uses_gateway}
      true -> resolved(Gateways.resolve(node))
    end
  rescue
    exception -> unavailable(exception)
  end

  defp resolved(:direct), do: {:ok, :direct}

  defp resolved({:gateway, gateway}) do
    case AccessKeys.active_keys(gateway) do
      [] -> {:error, :gateway_without_key}
      keys -> {:ok, {:gateway, gateway, Enum.take(keys, 2)}}
    end
  end

  defp resolved({:error, reason}), do: {:error, reason}

  # A key's scope is never refused a role here; what can refuse it is a feature that is off.
  defp may_post(scope) do
    case Access.authorize(scope, :"run.post_events", scope.workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # The run of this id the workspace holds already, as it decides the answer: none, a
  # repeat, or a run whose id is used.
  defp held(access_key, registration, digest) do
    run =
      Repo.one(
        from r in Run,
          where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^registration.run_id
      )

    case run do
      nil ->
        {:ok, nil}

      %Run{} = run ->
        if repeat?(run, access_key, digest), do: {:ok, {:repeat, run}}, else: held(run)
    end
  rescue
    exception -> unavailable(exception)
  end

  defp held(%Run{events_pruned_at: %DateTime{}}), do: {:error, :gone}
  defp held(%Run{} = run), do: {:ok, {:used, run}}

  # The same bytes under a key of the node that registered the run: the holder's retry of
  # the registration it sent, under the key it holds now.
  defp repeat?(%Run{} = run, access_key, digest),
    do: run.registration_digest == digest and Sender.registered_by?(run, access_key)

  # A repeat is given the answer the registration was given, nothing stored or admitted: the
  # same run key, signed again, for a run through a gateway; the run configuration, as
  # `answered/2` reads it, for a direct one.
  defp repeat(access_key, run) do
    if Run.through_gateway?(run) do
      {:ok, %{run: run, repeated: true, run_key: RunKey.encode(run.run_key_payload)}}
    else
      with {:ok, settings} <- answered(access_key, run),
           do: {:ok, Map.merge(settings, %{run: run, repeated: true})}
    end
  end

  @doc """
  The run configuration in force for a run of the key's workspace whose registration's
  labels are `labels` (`t:settings/0`): the stored bytes of a managed workspace, the
  document of no policy for one that serves none. `{:error, :unavailable}` when a managed
  workspace's cannot be read: never no policy, or the run would start without its policy.
  A direct registration and an attach are given it.
  """
  @spec configuration(AccessKey.t(), term) :: {:ok, settings} | {:error, :unavailable}
  def configuration(access_key, labels), do: settings(access_key, labels)

  defp settings(access_key, labels) do
    case Serving.fetch(access_key, labels) do
      {:ok, %RunConfiguration{document: document, digest: digest}} ->
        {:ok, settings(document, digest, true)}

      {:error, :unmanaged} ->
        document = Render.no_policy_document()
        {:ok, settings(document, Render.digest(document), false)}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  # The headers the answer carries come from here: `X-Qory-Run-Configuration` is the
  # digest, and the `ETag` the same string, quoted.
  defp settings(document, digest, managed),
    do: %{settings: document, digest: digest, etag: ~s("#{digest}"), managed: managed}

  # The answer the run's registration was given, by its digest.
  defp answered(access_key, %Run{registration_answer_digest: digest} = run),
    do: answered(access_key, run, digest)

  @doc """
  The run configuration a run was given under `digest`, for the key its place is read under
  (`Apiary.Runs.Sender.place_key/2`): the document of no policy, or the stored configuration
  of the run's workspace with that digest. One no longer stored is read again, as the run's
  registration's labels name it. A registration's repeat and an attach's are given it.
  """
  @spec answered(AccessKey.t(), Run.t(), String.t()) :: {:ok, settings} | {:error, :unavailable}
  def answered(access_key, %Run{} = run, digest) when is_binary(digest) do
    no_policy = Render.no_policy_document()

    stored =
      if digest == Render.digest(no_policy),
        do: no_policy,
        else:
          Repo.one(
            from c in RunConfiguration,
              where: c.workspace_id == ^run.workspace_id and c.digest == ^digest,
              limit: 1,
              select: c.document
          )

    case stored do
      nil -> settings(access_key, run.registration_labels)
      document -> {:ok, settings(document, digest, document != no_policy)}
    end
  rescue
    exception -> unavailable(exception)
  end

  # The refusals left, in the contract's order: the instance limit, then a run id that is
  # used, then the server's own (the configuration could not be read, or no run key could
  # be made). The answer is made before the transaction, outside the node's lock; the limit
  # is checked inside it, first, so a request every one of them refuses is refused by the
  # limit. No run is stored on any refusal.
  defp admit(held, route, access_key, registration, meta, digest, now) do
    answer = if held, do: :used, else: answer(route, access_key, registration, meta, now)

    store = fn ->
      case answer do
        :used -> {:error, :run_id_used}
        {:error, :unavailable} -> {:error, :unavailable}
        {:ok, answer} -> insert(access_key, registration, meta, digest, answer, now)
      end
    end

    result =
      if held_to_limit?(access_key, meta),
        do: Nodes.admit(access_key.node, meta.instance_id, store, now),
        else: Repo.transact(store)

    case result do
      {:ok, {:repeat, run}} ->
        repeat(access_key, run)

      {:ok, %{run: run}} = stored ->
        registered(access_key, run, meta, now)
        stored

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> unavailable(exception)
  end

  # A direct run is answered its run configuration; a run through a gateway its run key,
  # which names the gateway, with the attach window granted.
  defp answer(:direct, access_key, registration, _meta, _now),
    do: settings(access_key, registration.labels)

  defp answer({:gateway, gateway, keys}, access_key, registration, meta, now) do
    issued = DateTime.truncate(now, :second)
    attach_by = DateTime.add(issued, attach_window(registration.attach_seconds), :second)

    grant = %{
      run_id: registration.run_id,
      workspace: access_key.workspace.public_id,
      node_id: access_key.node.public_id,
      gateway: gateway.public_id,
      gateway_url: gateway.url,
      gateway_public_keys: Enum.map(keys, & &1.public_key),
      instance_id: meta[:instance_id],
      issued: issued,
      attach_by: attach_by
    }

    case RunKey.issue(grant) do
      {:ok, run_key, payload} ->
        {:ok,
         %{
           run_key: run_key,
           through: %{
             gateway_id: gateway.id,
             run_key_payload: payload,
             run_key_issued_at: usec(issued),
             attach_by: usec(attach_by)
           }
         }}

      {:error, reason} ->
        # The gateway's address is not one a run key may name, or makes it too long.
        Logger.error("no run key could be made for a run through a gateway: #{reason}")
        {:error, :unavailable}
    end
  end

  # A time to the second, as the column keeps microseconds.
  defp usec(%DateTime{} = time), do: %{time | microsecond: {0, 6}}

  # Whatever the database refuses or cannot do is `{:error, :unavailable}`, never an
  # exception into the request. The log line names the exception's module and nothing else.
  defp unavailable(exception) do
    Logger.error("a registration could not be stored: #{inspect(exception.__struct__)}")
    {:error, :unavailable}
  end

  # The instance limit holds a run an instance of the key's node claims.
  defp held_to_limit?(%AccessKey{node: %Nodes.Node{}}, meta), do: is_binary(meta[:instance_id])
  defp held_to_limit?(_access_key, _meta), do: false

  # Two registrations of one run may arrive at once: the insert that loses waits for the
  # one that wins and inserts nothing, and the read after it sees the row, locked for the
  # rest of the transaction. The loser is a repeat when its bytes and node are the
  # winner's, and the run id is used otherwise, which rolls back. An insert that loses to
  # a run of another workspace through the same gateway, under the same id, finds no row
  # here: the run id is used.
  defp insert(access_key, registration, meta, digest, answer, now) do
    {inserted, _rows} =
      Repo.insert_all(
        Run,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: access_key.organisation_id,
            workspace_id: access_key.workspace_id,
            run_id: registration.run_id,
            access_key_id: access_key.id,
            state: "pending",
            forager_version: forager_version(registration, meta),
            contract_version: meta.contract_version,
            registered_at: now,
            registration_labels: registration.labels,
            registration_about: registration.about,
            registration_digest: digest,
            registration_interval_seconds: registration.interval_seconds,
            registration_answer_digest: answer[:digest],
            registration_time: registration.time,
            # The registration stands for the record's sequence 1, never posted.
            projected_sequence: Run.projected_from(%{registered_at: now}),
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(Nodes.placement(access_key.node, meta[:instance_id]))
          |> Map.merge(answer[:through] || %{})
        ],
        on_conflict: :nothing
      )

    run =
      Repo.one(
        from r in Run,
          where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^registration.run_id,
          lock: "FOR UPDATE"
      )

    cond do
      is_nil(run) ->
        {:error, :run_id_used}

      inserted == 1 ->
        {:ok, answer |> Map.delete(:through) |> Map.merge(%{run: run, repeated: false})}

      repeat?(run, access_key, digest) ->
        {:ok, {:repeat, run}}

      true ->
        {:error, :run_id_used}
    end
  end

  # As the fold keeps Forager's version: at most 255 bytes, cut on a character boundary.
  # A registration through a gateway names none in its body: its attach does.
  defp forager_version(registration, meta) do
    case meta[:forager_version] || registration.forager_version do
      nil ->
        nil

      version when byte_size(version) <= 255 ->
        version

      version ->
        version |> binary_part(0, 255) |> String.chunk(:valid) |> List.first("")
    end
  end

  # Bookkeeping after the commit: it never fails the registration.
  defp registered(access_key, run, meta, now) do
    AccessKeys.touch_delivery(access_key, %{
      last_used_at: now,
      last_forager_version: meta[:forager_version],
      last_contract_version: meta.contract_version
    })

    Runs.broadcast_changed(run)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  The reload: the run configuration in force for the run `run_id`, for the key (an access
  key, or its scope). `{:ok, settings}` (`t:settings/0`), read by the labels the run
  registered with.

  `{:error, :not_found}` for a run id the key's workspace does not hold, a run another
  node registered (`Apiary.Runs.Sender`), a run that never registered (its batches created it), and a
  workspace that serves no run configuration: nobody has made its policy, the
  `security` feature is off, or `Apiary.Access` refuses `run_configuration.fetch`. That
  last is never the document of no policy, which would take the policy in force off a run
  that started under it: a policy removed mid-run never loosens a run already started.
  `{:error, :unavailable}` when the configuration cannot be read.
  """
  @spec fetch(AccessKey.t() | Scope.t(), term) ::
          {:ok, settings} | {:error, :not_found | :unavailable}
  def fetch(%Scope{access_key: %AccessKey{} = access_key}, run_id), do: fetch(access_key, run_id)

  def fetch(%AccessKey{} = access_key, run_id) do
    access_key = Repo.preload(access_key, [:workspace, :node])

    with true <- Batch.uuid?(run_id),
         %Run{} = run <- Repo.one(Sender.run_query(access_key, run_id)),
         true <- reload_allowed?(access_key, run) do
      case Serving.fetch(Sender.place_key(run, access_key), run.registration_labels) do
        {:ok, %RunConfiguration{document: document, digest: digest}} ->
          {:ok, settings(document, digest, true)}

        {:error, :unmanaged} ->
          without_run_configuration()

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      _not_found -> {:error, :not_found}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  # Who may reload a run: an active key of the node that registered it, and no other. A run
  # its batches created, which never registered, and a run whose node is gone are reloaded
  # by none.
  defp reload_allowed?(access_key, %Run{registered_at: %DateTime{}} = run),
    do: Sender.may_send?(run, access_key)

  defp reload_allowed?(_access_key, _run), do: false

  # A reload where the workspace serves no run configuration (nobody has made its policy,
  # the `security` feature is off, or `Apiary.Access` refuses `run_configuration.fetch`)
  # is not found, never the document of no policy: that answer would take the policy in
  # force off a run that started under it. A policy removed mid-run never loosens a run
  # already started.
  defp without_run_configuration, do: {:error, :not_found}
end

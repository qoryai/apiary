defmodule Apiary.Runs.Registration do
  @moduledoc """
  A run's registration: how a run starts on the server, and the run configuration it is
  given then and on a reload.

  `parse/1` reads the registration's body, decoded: `version`, `run_id`, `labels`,
  `about`, `time`, and the four members the run announces, `forager_version`,
  `contract_version`, `interval_seconds` and `events`. Every name of the body is read here
  and nowhere else. A body that breaks a rule is `{:error, :invalid_request, detail}`,
  where `detail` names the member and never repeats a value:

    * `version` is 1;
    * `run_id` is a UUID as the contract writes one (`Apiary.Runs.Batch.uuid?/1`);
    * `labels` is an object of at most 16 labels, each key 1 to 64 of `a-z`, `0-9`, `_`,
      `.` and `-`, each value a string of at most 256 bytes;
    * `about`, when sent, keeps every rule of `about` (`Apiary.Runs.About.validate/1`);
    * `time` is an RFC 3339 timestamp (`Apiary.Runs.Batch.time/1`); whether it is within
      `max_skew_seconds/0` of the server's clock is the caller's to ask (`fresh?/2`);
    * `forager_version` is a string that is not empty, `contract_version` an integer from
      1, `interval_seconds` an integer from 1 to 300, and `events` a list of strings that
      are not empty.

  A member the body does not name is ignored. The labels never name anything but the
  run's target, by the workspace's domain (`Apiary.Lingo.Domain`); `about` never selects
  a policy.

  `register/3` stores the run, in this order, each step answering or passing to the next:

    1. a key `Apiary.Access` does not let post (`run.post_events`) is `{:error, :not_found}`;
    2. a run of this id whose events retention has pruned is `{:error, :gone}`;
    3. a run of this id already stored is a repeat when it registered with the same bytes
       from the same node: nothing is stored or admitted again, and the answer is given
       again. Any other run of this id, another body, another node, or a run its events
       created without a registration, is `{:error, :run_id_used}`;
    4. the run configuration is read (`Apiary.Policy.Serving.fetch/2`): a managed workspace
       whose configuration cannot be read is `{:error, :unavailable}`, with nothing stored,
       never a run without its policy;
    5. the run is created, `pending`, on the key's node and the instance the request
       claimed (`Apiary.Nodes.placement/2`), with its registration, in the transaction of
       the instance limit (`Apiary.Nodes.admit/4`): an instance beyond the limit is
       `{:error, :instance_limit}`, nothing stored and the refusal counted on the node.

  Once committed, the key's use is recorded and the run is broadcast as changed. A later
  event of the run is stored on the same row (`Apiary.Runs.Ingest`), and its `run.started`
  moves it to `running`; the projector never writes the registration's fields.

  The answer is the run configuration in force for the target the labels name: for a
  managed workspace the stored bytes and their digest, exactly what
  `Apiary.Policy.Serving.fetch/2` reads; for a workspace that serves none, the document of
  no policy (`Apiary.Policy.Render.no_policy_document/0`) and its digest.

  `fetch/2` is the reload: the run configuration in force for a registered run, read by
  its registration's labels, for the node that registered it alone.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Nodes, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Policy.{Render, RunConfiguration, Serving}
  alias Apiary.Runs.{About, Batch, Run}

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

  @document_version 1
  @max_labels 16
  @label_key ~r/\A[a-z0-9_.-]{1,64}\z/
  @label_value 256
  @int4 2_147_483_647
  @max_skew_seconds 300

  @typedoc "A registration's body, as `parse/1` read it."
  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t(),
          labels: %{optional(String.t()) => String.t()},
          about: map,
          time: DateTime.t(),
          forager_version: String.t(),
          contract_version: pos_integer,
          interval_seconds: pos_integer,
          events: [String.t()]
        }

  @enforce_keys [
    :run_id,
    :labels,
    :about,
    :time,
    :forager_version,
    :contract_version,
    :interval_seconds,
    :events
  ]
  defstruct @enforce_keys

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
  (`Apiary.Policy.Render.digest/1`); `managed`, whether the workspace serves a run
  configuration of its own.
  """
  @type settings :: %{settings: binary, digest: String.t(), managed: boolean}

  @doc "The most seconds a registration's `time` may be from the server's clock."
  def max_skew_seconds, do: @max_skew_seconds

  @doc "Reads a registration's decoded body: see the moduledoc for the rules."
  @spec parse(term) :: {:ok, t} | {:error, :invalid_request, String.t()}
  def parse(%{} = body) do
    with :ok <- check(body[@version] == @document_version, @version),
         {:ok, run_id} <- run_id(body[@run_id]),
         {:ok, labels} <- labels(body[@labels]),
         {:ok, about} <- about(body),
         {:ok, time} <- time(body[@time]),
         {:ok, forager_version} <- forager_version(body[@forager_version]),
         {:ok, contract_version} <- contract_version(body[@contract_version]),
         {:ok, interval_seconds} <- interval_seconds(body[@interval_seconds]),
         {:ok, events} <- events(body[@events]) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         labels: labels,
         about: about,
         time: time,
         forager_version: forager_version,
         contract_version: contract_version,
         interval_seconds: interval_seconds,
         events: events
       }}
    end
  end

  def parse(_body), do: invalid("body")

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

  defp labels(%{} = labels) when map_size(labels) <= @max_labels do
    valid? =
      Enum.all?(labels, fn {key, value} ->
        Regex.match?(@label_key, key) and is_binary(value) and
          byte_size(value) <= @label_value and String.valid?(value)
      end)

    if valid?, do: {:ok, labels}, else: invalid(@labels)
  end

  defp labels(_labels), do: invalid(@labels)

  # Absent, it says nothing, as an empty `about` does.
  defp about(%{@about => about}) do
    case About.validate(about) do
      :ok -> {:ok, about}
      {:error, detail} -> invalid(detail)
    end
  end

  defp about(_body), do: {:ok, %{}}

  defp time(value) do
    case Batch.time(value) do
      {:ok, time} -> {:ok, time}
      :error -> invalid(@time)
    end
  end

  defp forager_version(value) when is_binary(value) and value != "", do: {:ok, value}
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
  it had registered with the same bytes before, and the run configuration it is given
  (`t:settings/0`). `{:error, reason}` with `:not_found`, `:gone`, `:run_id_used`,
  `:unavailable` or `:instance_limit`.
  """
  @spec register(AccessKey.t() | Scope.t(), t, meta) ::
          {:ok,
           %{required(:run) => Run.t(), required(:repeated) => boolean, optional(atom) => term}}
          | {:error, :not_found | :gone | :run_id_used | :unavailable | :instance_limit}
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
         {:ok, held} <- held(access_key, registration, digest),
         {:ok, settings} <- settings(access_key, registration.labels),
         {:ok, {run, repeated}} <-
           store(held, access_key, registration, meta, digest, now) do
      if not repeated, do: registered(access_key, run, meta, now)
      {:ok, Map.merge(settings, %{run: run, repeated: repeated})}
    end
  end

  # A key's scope is never refused a role here; what can refuse it is a feature that is off.
  defp may_post(scope) do
    case Access.authorize(scope, :"run.post_events", scope.workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # The run of this id the workspace holds already, if any, as it decides the answer.
  defp held(access_key, registration, digest) do
    run =
      Repo.one(
        from r in Run,
          where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^registration.run_id
      )

    case run do
      nil -> {:ok, nil}
      %Run{events_pruned_at: %DateTime{}} -> {:error, :gone}
      %Run{} = run -> if repeat?(run, access_key, digest), do: {:ok, run}, else: used()
    end
  rescue
    exception -> unavailable(exception)
  end

  # The same bytes from the same node: Forager's retry of the registration it sent.
  defp repeat?(%Run{} = run, access_key, digest),
    do: run.registration_digest == digest and run.node_id == access_key.node_id

  defp used, do: {:error, :run_id_used}

  # The run configuration the run is given. A managed workspace whose configuration cannot
  # be read is unavailable, never no policy: the run would start without its policy.
  defp settings(access_key, labels) do
    case Serving.fetch(access_key, labels) do
      {:ok, %RunConfiguration{document: document, digest: digest}} ->
        {:ok, %{settings: document, digest: digest, managed: true}}

      {:error, :unmanaged} ->
        document = Render.no_policy_document()
        {:ok, %{settings: document, digest: Render.digest(document), managed: false}}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp store(%Run{} = run, _access_key, _registration, _meta, _digest, _now),
    do: {:ok, {run, true}}

  # Whatever the database refuses or cannot do is `{:error, :unavailable}`, never an
  # exception into the request. The log line names the exception's module and nothing else.
  defp store(nil, access_key, registration, meta, digest, now) do
    insert = fn -> insert(access_key, registration, meta, digest, now) end

    if held_to_limit?(access_key, meta),
      do: Nodes.admit(access_key.node, meta.instance_id, insert, now),
      else: Repo.transact(insert)
  rescue
    exception -> unavailable(exception)
  end

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
  # winner's, and the run id is used otherwise, which rolls back.
  defp insert(access_key, registration, meta, digest, now) do
    {inserted, _rows} =
      Repo.insert_all(
        Run,
        [
          Map.merge(
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
              inserted_at: now,
              updated_at: now
            },
            Nodes.placement(access_key.node, meta[:instance_id])
          )
        ],
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :run_id]
      )

    run =
      Repo.one!(
        from r in Run,
          where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^registration.run_id,
          lock: "FOR UPDATE"
      )

    cond do
      inserted == 1 -> {:ok, {run, false}}
      is_nil(run.events_pruned_at) and repeat?(run, access_key, digest) -> {:ok, {run, true}}
      true -> used()
    end
  end

  # As the fold keeps Forager's version: at most 255 bytes, cut on a character boundary.
  defp forager_version(registration, meta) do
    version = meta[:forager_version] || registration.forager_version

    if byte_size(version) <= 255,
      do: version,
      else: version |> binary_part(0, 255) |> String.chunk(:valid) |> List.first("")
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
  The reload: the run configuration in force for the registered run `run_id`, for the key
  (an access key, or its scope). `{:ok, settings}` (`t:settings/0`), read by the labels
  the run registered with, else the labels its events gave it.

  `{:error, :not_found}` for a run id the key's workspace does not hold, a run the key's
  node did not register, and a workspace that serves no run configuration: nobody has made
  its policy, the `security` feature is off, or `Apiary.Access` refuses
  `run_configuration.fetch`. That last is never the document of no policy, which would
  take the policy in force off a run that started under it: a policy removed mid-run never
  loosens a run already started. `{:error, :unavailable}` when the configuration cannot be
  read.
  """
  @spec fetch(AccessKey.t() | Scope.t(), term) ::
          {:ok, settings} | {:error, :not_found | :unavailable}
  def fetch(%Scope{access_key: %AccessKey{} = access_key}, run_id), do: fetch(access_key, run_id)

  def fetch(%AccessKey{} = access_key, run_id) do
    access_key = Repo.preload(access_key, [:workspace, :node])

    with true <- Batch.uuid?(run_id),
         %Run{} = run <-
           Repo.one(
             from r in Run,
               where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^run_id
           ),
         true <- reload_allowed?(access_key, run) do
      case Serving.fetch(access_key, run.registration_labels || run.labels) do
        {:ok, %RunConfiguration{document: document, digest: digest}} ->
          {:ok, %{settings: document, digest: digest, managed: true}}

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

  # Who may reload a run: the node of the key that registered it (the node the run runs
  # on), and no other. A run on no node is reloaded by none.
  defp reload_allowed?(%AccessKey{node_id: node_id}, %Run{node_id: node_id})
       when is_binary(node_id),
       do: true

  defp reload_allowed?(_access_key, _run), do: false

  # A reload where the workspace serves no run configuration (nobody has made its policy,
  # the `security` feature is off, or `Apiary.Access` refuses `run_configuration.fetch`)
  # is not found, never the document of no policy: that answer would take the policy in
  # force off a run that started under it. A policy removed mid-run never loosens a run
  # already started.
  defp without_run_configuration, do: {:error, :not_found}
end

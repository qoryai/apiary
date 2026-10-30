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
    4. a repeat: the same gateway node and the same instance id, under any of the node's
       active keys, attaching the same run again while the run is live, is given the
       answer it was given, nothing stored again, while the gateway may still serve the
       run's workspace (`Apiary.Gateways.may_serve?/2`); once it may not, the repeat is
       `{:error, :workspace_not_served}`, and the run goes lost by liveness. A repeat is the gateway's, its
       instance's and the run's, not the body's bytes, so a gateway that restarted, or
       replaced its key, takes its run on again: a restarted gateway keeps its instance
       id. A run attached before its instance id was kept has none, and the first
       instance of its gateway that attaches it again is given the answer and becomes its
       attaching instance;
    5. a run that has ended is `{:error, :gone}`: its exit arrived, an outcome stored on
       it ended it (a run of a workspace's queue takes none, and one stored on it before
       that rule ends it all the same), it was released after its handover, it was lost
       after its attach, or its events were pruned. So is a run whose record is gone;
    6. a run never attached whose attach window has closed is
       `{:error, :run_key_expired}`: past `attach_by`, on the clock read once the run's row
       is locked, or already lost, as the lost-run check finds it at `attach_by` and a
       person's clearing of its instance leaves it;
    7. a run key that names another gateway is `{:error, :wrong_gateway}`;
    8. a gateway that may not serve the run's workspace (`Apiary.Gateways.may_serve?/2`),
       or that is deleted or gone, read `FOR SHARE` once the run's row is held, is
       `{:error, :workspace_not_served}`;
    9. a run another gateway node attached, or another instance of this one, is
       `{:error, :run_attached}`;
    10. a workspace whose run configuration cannot be read is `{:error, :unavailable}`;
    11. else the run is attached: when, its heartbeat interval, which
        the run is held to from then on (`Apiary.Runs.Liveness`), Forager's version and the
        contract's, the digest of the run configuration it is given, the instance id the
        attach was signed with, and, for a run given one, the deadline for its end
        (`backstop_at`, `Apiary.Runs.Liveness`).

  Since the gateway that attaches is the one the run key names, another gateway node
  never reaches the ninth answer once it passes the seventh; another instance of the
  gateway does, and is refused there. It stands so that no order of the checks lets a
  second gateway, or a second instance of one, take a run on.

  The instance is the attach's signed `X-Qory-Instance-Id`, given in `meta`. It is stored
  on the run beside the attach's answer (`runs.gateway_instance_id`), and from then on the
  run's batches, heartbeats and reloads are taken from that instance alone
  (`Apiary.Runs.Sender`), until the run's sending ends: once its exit arrived, it was lost
  after its attach, or its events were pruned, a batch from any instance of the gateway
  is answered as the attaching instance's would be. Its reloads stay that instance's. The
  attach itself is held to the answers above, an outcome's end included.

  The answer is the run configuration in force for the run's target, read under the
  run's place (`Apiary.Runs.Sender.place_key/2`), never the gateway's: its bytes, then
  `labels` and `about` of the run's registration, added after its last member, each left
  out when the run has none; and its digest, for `X-Qory-Run-Configuration` and `ETag`:
  the SHA-256 of the document's bytes without `labels` and `about`, the document a reload
  of the run returns. A run Qory set run variables for (`Apiary.Runs.Run`,
  `registration_variables`) receives a document composed for it with them after its last
  member (`Apiary.Policy.ComposedConfiguration`), and the digest is that document's. The
  variables are fixed when the run starts, so its reloads contain the same ones, and a run
  is never told its configuration moved because of them.

  A run given an image at the attach (`runs.configured_image`) has its configuration
  composed with that image at the top level, beside the `security_policy`
  (`Apiary.Policy.ComposedConfiguration`), and the digest is the composed document's. A
  run that must build on its pool's default image, of a workspace whose policy names an
  image, is given the policy without it. A workspace's policy that names an image gives
  no run an image. Any other run is given the configuration as stored. Every run keeps
  what it started in, which its reloads carry (`runs.started_image_from`,
  `runs.started_image`): the image it was given at the top level, the image the policy it
  was given names, or none.

  The gateway's row is read `FOR SHARE` in the attach's transaction, the way a gateway's
  deletion holds it (`Apiary.Gateways`), and the clock after it: a deletion either finds
  the run it would attach, or the attach finds the gateway deleted.

  No run is changed on any refusal. Once the run is attached, the batches, heartbeats and
  reloads of the gateway's attaching instance are taken for it, and nobody else's, but for
  a resend from another instance of the gateway once the run's sending has ended
  (`Apiary.Runs.Sender.sending_ended?/1`).
  """

  # With the `factory` feature:
  #
  # - Among the runs that have ended (5. above) is a prebuild whose run of the queue its
  #   starter's `prebuilt` ended, to any attach but a repeat.
  # - A run a workspace's queue handed over that is not a prebuild is given the image its
  #   claim read for it, the one the node pool that claimed it recorded for the run's
  #   target on its environment record (`Apiary.Environments.claim_image/2`), kept from
  #   the claim (`runs.configured_image`); for such a run its claim gave none, the image
  #   the pool recorded for the target its registration's labels name, read at the attach.
  #   Either is fixed at the attach; that is the run given an image at the attach. A prebuild
  #   whose workspace's policy names an image is given the policy without it. A run with
  #   no recorded image is given the configuration as stored.

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Dispatches, Environments, Gateways, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Runs.{Answer, Batch, Registration, Run, RunKey, Sender}

  @prebuild DispatchRun.prebuild()
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
  # The states of a run that has ended.
  @ended ~w(completed failed cancelled)

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
  `forager_version`, as its headers named it, and `instance_id`, the instance id it was
  signed with, each nil when not given. `{:ok, answer}`
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
    access_key = Repo.preload(access_key, [:workspace, :node])

    with :ok <- gateway(access_key),
         {:ok, grant, payload} <- verified(attach.run_key, run_id),
         {:ok, workspace, run} <- held(grant),
         :ok <- given(run, payload),
         :ok <- in_use(run),
         place = Sender.place_key(run, access_key),
         :ok <- may_post(place),
         {:ok, answer} <- store(run.id, access_key, grant, workspace, attach, meta) do
      if not answer.repeated, do: attached(access_key, answer.run, answer.run.attached_at)
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
           Repo.one(
             from r in Run, where: r.workspace_id == ^workspace.id and r.node_run_id == ^run_id
           ) do
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
  # of one run take turns and a pass never writes over the attach; then the gateway's row,
  # `FOR SHARE`, as its deletion holds it `FOR UPDATE`, so the two take turns as well. The
  # clock is read once the rows are held, so the window is judged against the row as it is
  # then.
  defp store(id, access_key, grant, workspace, attach, meta) do
    Repo.transact(fn ->
      Runs.Projector.lock(id)
      run = Repo.one!(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

      # Nil once the gateway's row is gone: it may serve nothing.
      gateway = Repo.one(from n in Node, where: n.id == ^access_key.node_id, lock: "FOR SHARE")
      now = DateTime.utc_now()

      cond do
        # A repeat is held to the workspace as the first attach is: a gateway that may no
        # longer serve it is refused, and the run goes lost by liveness.
        repeat?(run, gateway, meta[:instance_id]) and not Gateways.may_serve?(gateway, workspace) ->
          {:error, :workspace_not_served}

        repeat?(run, gateway, meta[:instance_id]) ->
          repeat(access_key, run, meta[:instance_id])

        ended?(run) or prebuilt?(run) ->
          {:error, :gone}

        expired?(run, now) ->
          {:error, :run_key_expired}

        grant.gateway != access_key.node.public_id or run.gateway_id != access_key.node_id ->
          {:error, :wrong_gateway}

        not Gateways.may_serve?(gateway, workspace) ->
          {:error, :workspace_not_served}

        not is_nil(run.attached_at) ->
          {:error, :run_attached}

        true ->
          take(access_key, run, workspace, attach, meta, now)
      end
    end)
  end

  # Never attached, and its window closed: past `attach_by`, or already found lost, by the
  # lost-run check at `attach_by` or by a person clearing its instance.
  defp expired?(%Run{attached_at: nil} = run, now),
    do: run.state == "lost" or DateTime.compare(now, run.attach_by) == :gt

  defp expired?(_run, _now), do: false

  # The gateway that attached the run, under any of its keys, and the instance that
  # attached it, or any of its instances while that is not known, while the run is live.
  defp repeat?(%Run{attached_at: %DateTime{}, gateway_id: id} = run, %Node{id: id}, instance_id),
    do: not ended?(run) and Sender.attaching_instance?(run, instance_id)

  defp repeat?(_run, _gateway, _instance_id), do: false

  # Its exit arrived, an outcome stored on it ended it (a run of the queue takes none; one
  # stored before that rule ends it all the same), its starter released it after a queue
  # handed it over (cancelled, `released_at`, `Apiary.Dispatches.RunEnd`), or it was lost
  # after its attach; or retention pruned its events, and the workspace wants nothing more
  # of it.
  defp ended?(%Run{} = run) do
    run.state in @ended or not is_nil(run.exited_at) or not is_nil(run.outcome_state) or
      not is_nil(run.events_pruned_at) or (run.state == "lost" and not is_nil(run.attached_at))
  end

  # A prebuild whose run of the queue its starter's `prebuilt` ended
  # (`Apiary.Dispatches.RunEnd`): the gateway that attached it keeps it, as a repeat, and
  # no other attach takes it on.
  defp prebuilt?(%Run{dispatch_run_id: nil}), do: false

  defp prebuilt?(%Run{dispatch_run_id: id}),
    do: Repo.exists?(from d in DispatchRun, where: d.id == ^id and d.end_cause == :prebuilt)

  # A run attached before its instance was known takes this one's, under the run's row
  # lock: the attach that wrote it first holds the run.
  defp repeat(access_key, run, instance_id) do
    with {:ok, run} <- taken(run, instance_id),
         {:ok, settings} <-
           Registration.answered(Sender.place_key(run, access_key), run, run.attach_answer_digest),
         do: {:ok, answer(run, settings, true)}
  end

  defp taken(run, instance_id) do
    case Sender.take_instance(run, instance_id) do
      {:ok, run} -> {:ok, run}
      {:error, :other_instance} -> {:error, :run_attached}
    end
  end

  defp take(access_key, run, workspace, attach, meta, now) do
    dispatched = dispatched(run)

    with {:ok, settings, image} <-
           Registration.configuration(Sender.place_key(run, access_key), run.registration_labels,
             image: fn -> image(run, workspace, dispatched) end,
             prebuild: prebuild?(dispatched),
             run: run
           ) do
      {started_from, started_image} = started(settings.settings, image)

      run =
        run
        |> Ecto.Changeset.change(
          attached_at: now,
          attach_interval_seconds: attach.interval_seconds,
          attach_answer_digest: settings.digest,
          gateway_instance_id: kept_instance(meta[:instance_id]),
          forager_version: kept_version(meta[:forager_version] || attach.forager_version),
          contract_version: attach.contract_version,
          backstop_at: backstop_at(dispatched, now),
          configured_image: image,
          started_image_from: started_from,
          started_image: started_image,
          updated_at: now
        )
        |> Repo.update!()

      {:ok, answer(run, settings, false)}
    end
  end

  # What the run starts in, which its reloads carry (`Apiary.Runs.Run`): the image it is
  # given at the top level, else the image the `security_policy` it is given names, else
  # none.
  defp started(_document, image) when is_binary(image), do: {"top_level", image}

  defp started(document, nil) do
    case ComposedConfiguration.policy_image(document) do
      nil -> {"none", nil}
      image -> {"policy", image}
    end
  end

  # For a run a workspace's queue handed over, its step and the node pool that claimed
  # it, whose dispatch was handed over; nil for any other run.
  defp dispatched(%Run{dispatch_run_id: nil}), do: nil

  defp dispatched(%Run{dispatch_run_id: id}) do
    Repo.one(
      from r in DispatchRun,
        left_join: d in Dispatch,
        on: d.dispatch_run_id == r.id and not is_nil(d.handed_over_at),
        where: r.id == ^id,
        order_by: [desc: d.handed_over_at],
        limit: 1,
        select: %{step: r.step, pool_id: d.pool_id}
    )
  end

  defp prebuild?(%{step: step}), do: step == DispatchRun.prebuild()
  defp prebuild?(nil), do: false

  # The image a run starts in: for a run a workspace's queue handed over, not a prebuild,
  # the image its claim read for it (`runs.configured_image`,
  # `Apiary.Environments.claim_image/2`), read again here through the registry's place of
  # the run's organisation (`Apiary.Environments.own_image/2`): a claim made before that
  # check could read an image elsewhere, and such a run starts in the pool's default
  # image; for such a run its claim gave none, the image
  # the pool that claimed it recorded for the run's target, the one its registration's
  # labels name (`Apiary.Environments.image_for/3`); nil for any other run, which starts
  # in the pool's default.
  defp image(%Run{configured_image: image} = run, _workspace, %{step: step, pool_id: pool_id})
       when is_binary(image) and is_binary(pool_id) and step != @prebuild,
       do: Environments.own_image(image, run.workspace_id)

  defp image(%Run{} = run, workspace, %{step: step, pool_id: pool_id})
       when is_binary(pool_id) do
    with false <- step == DispatchRun.prebuild(),
         %Node{kind: :pool} = pool <- Repo.get(Node, pool_id),
         {:ok, target} <- Domain.target(workspace, run.registration_labels) do
      Environments.image_for(pool, run.workspace_id, target)
    else
      _none -> nil
    end
  end

  defp image(_run, _workspace, _dispatched), do: nil

  # A run a workspace's queue handed over is lost should it have no exit by its step's
  # limit after its attach, nor, for a run that is not a prebuild, an outcome stored on it
  # before a run of the queue was refused one (`Apiary.Dispatches.RunEnd`). Any other run
  # has no such deadline.
  defp backstop_at(nil, _now), do: nil

  defp backstop_at(%{step: step}, now),
    do: DateTime.add(now, Dispatches.backstop_seconds(step), :second)

  # The instance id the request was signed with, when it can be kept; nil otherwise, so the
  # run's next request from its gateway gives it one.
  defp kept_instance(instance_id),
    do: if(Instance.instance_id?(instance_id), do: instance_id)

  # As the fold keeps Forager's version: at most 255 bytes, cut on a character boundary.
  defp kept_version(version) when byte_size(version) <= 255, do: version

  defp kept_version(version),
    do: version |> binary_part(0, 255) |> String.chunk(:valid) |> List.first("")

  # The answer's bytes, under the digest of the document without `labels` and `about`.
  defp answer(run, %{settings: document} = settings, repeated) do
    body = answer_body(document, run.registration_labels, run.registration_about)
    Map.merge(settings, %{settings: body, run: run, repeated: repeated})
  end

  @doc """
  The bytes of an attach's answer: the run configuration `document`, with `labels` and
  `about` added after its last member, each only when it holds something. Its digest
  stays the document's.
  """
  @spec answer_body(binary, map | nil, map | nil) :: binary
  def answer_body(document, labels, about) when is_binary(document),
    do: Answer.append_members(document, [{"labels", labels}, {"about", about}])

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

defmodule Mix.Tasks.Apiary.Demo do
  @shortdoc "Replays the synthetic runs under priv/demo into a workspace (dev and test only)"

  @moduledoc """
  Replays recorded runs into a workspace, so that there is something to look at while the
  console is being built. A development tool: it refuses to run in production.

      mix apiary.demo
      mix apiary.demo --key ak_0123456789abcdef
      mix apiary.demo --file priv/demo/failed-run/events.jsonl

  Every directory of `priv/demo` is one run, all of it synthetic: `registration.json`, the
  body of its registration (`POST /v1/runs`), and `events.jsonl`, the events it posted,
  one CloudEvent of the server contract per line, from sequence 2, since the registration
  stands for sequence 1; `registered-only`'s is empty, a run that registered and posted
  nothing. `--file` replays one `events.jsonl` instead, with the registration beside it. The run lands in the
  workspace of the access key named by `--key`, a node's key id, on that key's node;
  without it, in the first workspace that has a key that is not revoked, under its newest
  such key: on a new instance, the Main workspace of the organisation its set-up link
  made (`Apiary.Setup`), once a key is added to a node there.

  Nothing is inserted from here. A run goes the way Forager's goes: its registration, read
  by `Apiary.Runs.Registration.parse/1` and stored by `Apiary.Runs.Registration.register/3`,
  then its events, cut into batches of 20, each parsed by `Apiary.Runs.Batch` and stored
  by `Apiary.Runs.Ingest`, the functions the receiver calls once it has verified a
  request, and then projected. Each invocation makes new runs: the run id and every event
  id are fresh, and the times are shifted so that the last event of the file, or the
  registration of a run that posted none, happens now. A run that exits has just
  exited; one that does not has just beaten, and is found lost once its heartbeats have
  been missing for three of its intervals, like any run that stops talking.

  Once the runs are in, a workspace that has no security policy yet is given one, through
  `Apiary.Policy` as a page would and in the name of the workspace's first owner: enforce,
  a baseline of hosts, one held to paths, a locked deny, and in the target
  `codeberg.org/acme/shop` an added host, a disabled one, an allow the lock
  overrides and a mode of its own (observe, under a workspace that enforces); written rule
  by rule, so there are versions and a history to look at, and the workspace is a managed
  one, serving its run configuration. A workspace whose policy anybody has changed, even
  back to nothing, is left as it is.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Workspace, Membership}
  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Ingest, Projector, Registration, Target, Run}

  @batch_size 20
  @source_prefix "urn:qory:run:"
  @policy_applied "dev.qory.run.policy_applied"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod, do: Mix.raise("mix apiary.demo is a development tool: not in prod")

    {opts, _rest} = OptionParser.parse!(args, strict: [key: :string, file: :string])

    Mix.Task.run("app.start")
    # The query log of a replay is a few hundred lines nobody asked for.
    Logger.configure(level: :warning)

    access_key = access_key!(opts[:key])
    files = if opts[:file], do: [opts[:file]], else: files()
    if files == [], do: Mix.raise("no events.jsonl under #{demo_dir()}")

    Mix.shell().info("Replaying into the workspace of #{access_key.key_id}")

    %{organisation: organisation, workspace: workspace} =
      Repo.preload(access_key, [:organisation, :workspace])

    runs_url = "#{ApiaryWeb.Endpoint.url()}/#{organisation.slug}/#{workspace.slug}/runs"

    for file <- files do
      case replay(access_key, file) do
        {:ok, %Run{} = run} ->
          Mix.shell().info("""

          #{file |> Path.relative_to(Application.app_dir(:apiary)) |> Path.relative_to_cwd()}
            run id  #{run.run_id}
            state   #{run.state}, #{run.event_count} events
            url     #{runs_url}/#{run.run_id}\
          """)

        {:error, reason} ->
          Mix.raise("#{file} was not replayed: #{inspect(reason)}")
      end
    end

    # An instance without the security feature has no policy to give the workspace.
    if Apiary.Features.on?(access_key, :security), do: demo_policy(access_key)
  end

  defp demo_policy(access_key) do
    case policy(access_key) do
      {:ok, changes} ->
        Mix.shell().info("\nThe workspace has a security policy now: #{changes} changes.")

      :kept ->
        Mix.shell().info("\nThe workspace's security policy is left as it is.")

      {:error, reason} ->
        Mix.raise("the security policy was not written: #{reason}")
    end
  end

  @doc """
  Gives the key's workspace the demo's security policy, when nobody has made its policy
  yet (`Apiary.Policy.managed?/1`; a workspace whose rules were all removed again has
  been): `{:ok, changes}` with how many changes were made, `:kept` for a workspace with
  any change, or `{:error, sentence}`. Synthetic hosts only, the ones the recorded runs
  reach.
  """
  def policy(%AccessKey{workspace_id: workspace_id}) do
    with %Scope{} = scope <- owner_scope(workspace_id),
         false <- Policy.managed?(scope) do
      shop =
        Repo.get_by(Target,
          workspace_id: workspace_id,
          system: "codeberg.org",
          path: "acme/shop"
        )

      steps =
        [
          &Policy.allow(&1, nil, %{host: "api.llm.example"}),
          &Policy.allow(&1, nil, %{host: "packages.example.com"}),
          &Policy.allow(&1, nil, %{host: "*.packages.example.com"}),
          &Policy.allow(&1, nil, %{host: "registry.example"}),
          &Policy.allow(&1, nil, %{host: "metrics.example"}),
          &Policy.allow(&1, nil, %{
            host: "codeberg.org",
            paths: ["/acme/shop.git/info/refs", "/acme/shop.git/git-upload-pack"]
          }),
          &Policy.deny(&1, nil, %{host: "telemetry.llm.example", locked: true}),
          &Policy.set_mode(&1, "enforce"),
          &remove(&1, "metrics.example")
        ] ++
          if shop do
            [
              &Policy.allow(&1, shop, %{host: "api.example"}),
              &Policy.deny(&1, shop, %{host: "registry.example"}),
              &Policy.allow(&1, shop, %{host: "telemetry.llm.example"}),
              # The workspace enforces; this target is still being watched.
              &Policy.set_mode(&1, shop, "observe")
            ]
          else
            []
          end

      Enum.reduce_while(steps, {:ok, 0}, fn step, {:ok, count} ->
        case step.(scope) do
          {:ok, _value} -> {:cont, {:ok, count + 1}}
          {:error, %Policy.Error{message: message}} -> {:halt, {:error, message}}
        end
      end)
    else
      nil -> {:error, "the workspace has no owner"}
      true -> :kept
    end
  end

  defp remove(scope, host) do
    rule = Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))
    Policy.remove_rule(scope, rule)
  end

  # The scope of the first owner of the workspace's organisation, who reaches every
  # workspace of it: the policy is written in somebody's name, and the demo's sets the
  # mode. Which membership to write as is a choice of data; whether it may is
  # `Apiary.Policy`'s question to `Apiary.Access`.
  defp owner_scope(workspace_id) do
    workspace = Repo.get(Workspace, workspace_id)

    membership =
      workspace &&
        Repo.one(
          from m in Membership,
            where: m.organisation_id == ^workspace.organisation_id and m.level == :owner,
            order_by: [asc: m.inserted_at, asc: m.id],
            limit: 1,
            preload: [:user, :organisation]
        )

    if membership do
      %Scope{
        user: membership.user,
        organisation: membership.organisation,
        workspace: workspace,
        membership: membership
      }
    end
  end

  @doc """
  The recorded runs that ship with the repository, each its `events.jsonl`, in the order of
  their names.
  """
  def files do
    demo_dir() |> Path.join("*/events.jsonl") |> Path.wildcard() |> Enum.sort()
  end

  defp demo_dir, do: Application.app_dir(:apiary, "priv/demo")

  @doc """
  Replays one `events.jsonl` as a new run in the workspace of `access_key`, registered by
  the `registration.json` beside it, its last event happening at `now`, and projects it.
  `{:ok, run}` with the run as projected; `{:error, reason}` when a file is not what it
  should be, a batch does not parse or the workspace does not take the run.
  """
  def replay(%AccessKey{} = access_key, file, now \\ DateTime.utc_now()) do
    with {:ok, events} <- read(file),
         {:ok, body} <- read_registration(file) do
      {body, events} = renew(body, events, Ecto.UUID.generate(version: 7), now)
      meta = meta(body, events)

      # Everything is read before anything is stored: a file that is not a record stores
      # nothing.
      with {:ok, registration} <- parse_registration(body),
           {:ok, batches} <- batches(events),
           {:ok, run} <- register(access_key, registration, body) do
        batches
        |> Enum.reduce_while({:ok, run}, fn batch, _last ->
          case deliver(access_key, batch, meta) do
            {:ok, run} -> {:cont, {:ok, run}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, run} -> Projector.project(run)
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp parse_registration(body) do
    case Registration.parse(body) do
      {:ok, registration} -> {:ok, registration}
      {:error, :invalid_request, member} -> {:error, {:not_a_registration, member}}
    end
  end

  defp batches(events) do
    events
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, batches} ->
      case parse(chunk) do
        {:ok, batch} -> {:cont, {:ok, [batch | batches]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, Enum.reverse(batches)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The registration's body, as Forager posts it: stored by the receiver's own function.
  defp register(access_key, registration, body) do
    meta = %{
      body: Jason.encode!(body),
      contract_version: 1,
      forager_version: body["forager_version"]
    }

    case Registration.register(access_key, registration, meta) do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_registration(file) do
    path = file |> Path.dirname() |> Path.join("registration.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"time" => time} = body} when is_binary(time) <- Jason.decode(bytes) do
      {:ok, body}
    else
      {:error, :enoent} -> {:error, :no_registration}
      _ -> {:error, :not_a_registration}
    end
  end

  defp read(file) do
    with {:ok, body} <- File.read(file) do
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce_while([], fn line, events ->
        case Jason.decode(line) do
          {:ok, %{"time" => time} = event} when is_binary(time) -> {:cont, [event | events]}
          _ -> {:halt, :error}
        end
      end)
      |> case do
        :error -> {:error, :not_events}
        events -> {:ok, Enum.reverse(events)}
      end
    end
  end

  # A new run made of new events, ending now: what the record said relative to its own
  # end, it says relative to this moment. The registration's time is to the whole second,
  # as the contract writes it.
  defp renew(registration, events, subject, now) do
    last = [registration | events] |> Enum.map(&time!/1) |> Enum.max(DateTime)
    shift = DateTime.diff(now, last, :millisecond)
    at = &(&1 |> time!() |> DateTime.add(shift, :millisecond) |> DateTime.truncate(&2))

    events =
      for event <- events do
        Map.merge(event, %{
          "id" => Ecto.UUID.generate(),
          "subject" => subject,
          "source" => @source_prefix <> subject,
          "time" => event |> at.(:millisecond) |> DateTime.to_iso8601()
        })
      end

    registration =
      Map.merge(registration, %{
        "run_id" => subject,
        "time" => registration |> at.(:second) |> DateTime.to_iso8601()
      })

    {registration, events}
  end

  defp time!(%{"time" => time}) do
    {:ok, time, 0} = DateTime.from_iso8601(time)
    time
  end

  # What the gateway's request would have said in its headers: revision 1 of the contract,
  # as on every request.
  defp meta(registration, events) do
    %{
      forager_version: registration["forager_version"],
      contract_version: 1,
      run_configuration: data(events, @policy_applied)["run_configuration"]
    }
  end

  defp data(events, type) do
    Enum.find_value(events, %{}, fn event -> if event["type"] == type, do: event["data"] end)
  end

  defp deliver(access_key, batch, meta) do
    case Ingest.ingest(access_key, batch, Map.put(meta, :delivery_id, Ecto.UUID.generate())) do
      {:ok, %{status: 202, run: run}} -> {:ok, run}
      {:ok, %{status: status}} -> {:error, {:refused, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(events) do
    case Batch.parse(Jason.encode!(events)) do
      {:ok, batch} -> {:ok, batch}
      :error -> {:error, :not_a_batch}
    end
  end

  @doc false
  # The key a replay posts under, as a verified request carries it, with its workspace and
  # node: `--key`'s, or the newest key, neither revoked nor of a deleted node, of
  # the first workspace that has one. Public for the tests.
  def access_key!(nil) do
    if not Repo.exists?(Workspace), do: Mix.raise("there is no workspace yet: sign up first")

    key_id =
      Repo.one(
        from k in AccessKey,
          join: w in assoc(k, :workspace),
          join: n in assoc(k, :node),
          where: is_nil(k.revoked_at) and is_nil(n.deleted_at),
          order_by: [asc: w.inserted_at, asc: w.id, desc: k.inserted_at, desc: k.id],
          limit: 1,
          select: k.key_id
      ) || Mix.raise("no workspace has an access key: add one to a node")

    access_key!(key_id)
  end

  def access_key!(key_id) do
    case AccessKeys.fetch_for_verification(key_id) do
      {:ok, %AccessKey{} = access_key} -> access_key
      _ -> Mix.raise("no access key #{key_id} that is not revoked")
    end
  end
end

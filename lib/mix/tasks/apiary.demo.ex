defmodule Mix.Tasks.Apiary.Demo do
  @shortdoc "Replays the synthetic runs under priv/demo into a hive (dev and test only)"

  @moduledoc """
  Replays recorded runs into a hive, so that there is something to look at while the
  console is being built. A development tool: it refuses to run in production.

      mix apiary.demo
      mix apiary.demo --key ak_0123456789abcdef
      mix apiary.demo --file priv/demo/failed-run/events.jsonl

  Every `priv/demo/*/events.jsonl` is one run, one CloudEvent of the server contract per
  line, all of it synthetic. `--file` replays one file instead. The run lands in the hive
  of the access key named by `--key`, a key id; without it, in the first hive, under its
  newest key that is not revoked.

  Nothing is inserted from here. A file goes the way a delivery goes: cut into batches of
  20 events, each parsed by `Apiary.Runs.Batch` and stored by `Apiary.Runs.Ingest`, the
  function the receiver calls once it has verified a request, and then projected. Each
  invocation makes new runs: the run id and every event id are fresh, and the times are
  shifted so that the last event of the file happens now. A run that exits has just
  exited; one that does not has just beaten, and is found lost once its heartbeats have
  been missing for three of its intervals, like any run that stops talking.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Organisations.Hive
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Ingest, Projector, Run}

  @batch_size 20
  @source_prefix "urn:qory:run:"
  @ping "ai.qory.ping"
  @policy_applied "ai.qory.run.policy_applied"

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

    Mix.shell().info("Replaying into the hive of #{access_key.key_id}")

    for file <- files do
      case replay(access_key, file) do
        {:ok, %Run{} = run} ->
          Mix.shell().info("""

          #{file |> Path.relative_to(Application.app_dir(:apiary)) |> Path.relative_to_cwd()}
            run id  #{run.run_id}
            state   #{run.state}, #{run.event_count} events
            url     #{ApiaryWeb.Endpoint.url()}/hive/runs/#{run.run_id}\
          """)

        {:error, reason} ->
          Mix.raise("#{file} was not replayed: #{inspect(reason)}")
      end
    end
  end

  @doc "The recorded runs that ship with the repository, in the order of their names."
  def files do
    demo_dir() |> Path.join("*/events.jsonl") |> Path.wildcard() |> Enum.sort()
  end

  defp demo_dir, do: Application.app_dir(:apiary, "priv/demo")

  @doc """
  Replays one `events.jsonl` as a new run in the hive of `access_key`, its last event
  happening at `now`, and projects it. `{:ok, run}` with the run as projected;
  `{:error, reason}` when the file holds no events, a batch does not parse or the hive
  does not take it.
  """
  def replay(%AccessKey{} = access_key, file, now \\ DateTime.utc_now()) do
    with {:ok, events} <- read(file) do
      events = renew(events, Ecto.UUID.generate(version: 7), now)
      meta = meta(events)

      events
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while({:error, :empty}, fn chunk, _last ->
        case deliver(access_key, chunk, meta) do
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
        [] -> {:error, :empty}
        events -> {:ok, Enum.reverse(events)}
      end
    end
  end

  # A new run made of new events, ending now: what the record said relative to its own
  # end, it says relative to this moment.
  defp renew(events, subject, now) do
    last = events |> Enum.map(&time!/1) |> Enum.max(DateTime)
    shift = DateTime.diff(now, last, :millisecond)

    for event <- events do
      time =
        event
        |> time!()
        |> DateTime.add(shift, :millisecond)
        |> DateTime.truncate(:millisecond)
        |> DateTime.to_iso8601()

      Map.merge(event, %{
        "id" => Ecto.UUID.generate(),
        "subject" => subject,
        "source" => @source_prefix <> subject,
        "time" => time
      })
    end
  end

  defp time!(%{"time" => time}) do
    {:ok, time, 0} = DateTime.from_iso8601(time)
    time
  end

  # What the runner's request would have said in its headers.
  defp meta(events) do
    ping = data(events, @ping)

    %{
      runner_version: ping["runner_version"],
      contract_version: ping["contract_version"],
      run_configuration: data(events, @policy_applied)["run_configuration"]
    }
  end

  defp data(events, type) do
    Enum.find_value(events, %{}, fn event -> if event["type"] == type, do: event["data"] end)
  end

  defp deliver(access_key, events, meta) do
    with {:ok, batch} <- parse(events),
         {:ok, %{status: 202, run: run}} <-
           Ingest.ingest(access_key, batch, Map.put(meta, :delivery_id, Ecto.UUID.generate())) do
      {:ok, run}
    else
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

  defp access_key!(nil) do
    hive = Repo.one(from h in Hive, order_by: [asc: h.inserted_at, asc: h.id], limit: 1)
    if is_nil(hive), do: Mix.raise("there is no hive yet: sign up first")

    key =
      Repo.one(
        from k in AccessKey,
          where: k.hive_id == ^hive.id and is_nil(k.revoked_at),
          order_by: [desc: k.inserted_at, desc: k.id],
          limit: 1
      )

    key || Mix.raise("the first hive has no access key that is not revoked: create one")
  end

  defp access_key!(key_id) do
    case AccessKeys.fetch_for_verification(key_id) do
      {:ok, access_key} -> access_key
      :error -> Mix.raise("no access key #{key_id} that is not revoked")
    end
  end
end

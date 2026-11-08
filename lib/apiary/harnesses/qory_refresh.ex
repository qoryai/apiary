defmodule Apiary.Harnesses.QoryRefresh do
  @moduledoc false

  # Reads the newest commit of the Qory harness's `main`, and of each branch a harness
  # choice of the Qory harness follows, at the address the instance sets now, and keeps
  # their files (`Apiary.Harnesses.Qory.read/1`), so the pages read those commits' files
  # from the database. A tag and a commit never move: one is read only while its files
  # are not kept at that address, as after the address changed. Oban's cron
  # plugin enqueues it every five minutes, from the crontab the application starts Oban
  # with, and the application enqueues it once at boot (`enqueue_at_boot/0`); it is the
  # instance's work and names no organisation. A read that fails is one line in the log,
  # and the next run tries again: the pages keep the files of the last commit read.
  # After the reads, each workspace whose process is kept at the latest is updated to the
  # commit its branch was read at (`Apiary.Processes.HarnessUpdate.follow_all/0`).
  use Apiary.Job,
    scope: :instance,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Harnesses.Qory
  alias Apiary.Repo
  alias Apiary.Stacks.Stack

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{}) do
    for {kind, name} = version <- Enum.map(branches(), &{:branch, &1}) ++ unread() do
      case Qory.read(version) do
        {:ok, _commit} ->
          :ok

        {:error, failure} ->
          Logger.warning(
            "the Qory harness could not be read #{kind}=#{name} failure=#{inspect(failure)}"
          )
      end
    end

    Apiary.Processes.HarnessUpdate.follow_all()
  end

  # `main`, then each other branch a row of the Qory harness's choice follows, by name.
  defp branches do
    chosen =
      Repo.all(
        from s in Stack,
          where: s.choice == :qory and s.version_kind == :branch,
          distinct: true,
          order_by: s.version_name,
          select: s.version_name
      )

    Enum.uniq([Qory.default_branch() | chosen])
  end

  # Each tag and commit a row of the Qory harness's choice has, whose files are not kept
  # at the address the instance sets now (`Apiary.Harnesses.Qory.head/1`).
  defp unread do
    Repo.all(
      from s in Stack,
        where: s.choice == :qory and s.version_kind in [:tag, :commit],
        distinct: true,
        order_by: [s.version_kind, s.version_name],
        select: {s.version_kind, s.version_name}
    )
    |> Enum.reject(&Qory.head/1)
  end

  @doc false
  # enqueue_at_boot/0 enqueues one refresh, once the application's processes run, so the
  # pages have the files of `main` without waiting for the cron; a refresh already
  # waiting is not enqueued again. Off under test (`config :apiary, __MODULE__, at_boot:
  # false`), where `Apiary.QoryHarnessFixture` keeps the files. A failed insert is one
  # line in the log, and the cron reads `main` next.
  @spec enqueue_at_boot() :: :ok
  def enqueue_at_boot do
    if :apiary |> Application.get_env(__MODULE__, []) |> Keyword.get(:at_boot, true) do
      case Oban.insert(new(%{})) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("the Qory harness refresh was not enqueued: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "the Qory harness refresh was not enqueued: #{inspect(exception.__struct__)}"
      )

      :ok
  end
end

defmodule Apiary.Runs.TargetWrite do
  @moduledoc """
  One state of one write a run sent to a place in another system, folded from its
  `dev.qory.run.target_write` event, one row per event. A projection: rebuilt from
  `events`, and deleted with them (`Apiary.Retention`).

  `sequence` and `at` are the event's. `system` and `path` are the place the write went
  to, each a label that can name a target (`Apiary.Runs.Target.label/1`): the software
  domain reads them as the forge and the repository. `target_id` is the workspace's
  target with that system and path, nil for none; the projector creates no target for a
  write. `request_id` is the proxy's id of the request, nil when the event has none.

  `state` is one of:

    * `started`: the write began;
    * `changed`: the system reported the write done, in part or whole;
    * `refused`: the system reported the write not done;
    * `cut`: the write ended without a report, so the system may have applied it.

  One write has a `started`, then one of the three ends, both with its `request_id`.
  `writes/2` reads them as one.
  """
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.Repo
  alias Apiary.Runs.Run

  @typedoc "One state of one write of one run."
  @type t :: %__MODULE__{}

  @states ~w(started changed refused cut)

  @doc "The states a write can be in."
  def states, do: @states

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_target_writes" do
    field :sequence, :integer
    field :at, :utc_datetime_usec
    field :system, :string
    field :path, :string
    field :state, :string
    field :request_id, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
    belongs_to :target, Apiary.Runs.Target
  end

  @doc """
  The rows of the run, in sequence order.
  """
  @spec of_run(Run.t()) :: [t()]
  def of_run(%Run{id: id}),
    do: Repo.all(from w in __MODULE__, where: w.run_id == ^id, order_by: w.sequence)

  @doc """
  What the run wrote to each place, from its rows (`of_run/1`), one entry per system and
  path in the order of their first row: `%{system:, path:, target_id:, written:}`, where
  `written` is

    * `:changed` when a write to it changed it;
    * `:maybe` when none did, and a write to it started or was cut;
    * `:refused` when every write to it was refused.

  The rows with one `request_id` are one write, in the state of the row with the highest
  sequence; a row with no `request_id` is a write alone. A write still `started` reads as
  `cut` once the run has ended (`ended?`): the gateway ends every open write before the
  run's exit, unless it stops first, and then nobody knows whether the system applied it.
  """
  @spec writes([t()], boolean) :: [map]
  def writes(rows, ended?) when is_list(rows) and is_boolean(ended?) do
    rows = Enum.sort_by(rows, & &1.sequence)

    states =
      rows
      |> Enum.group_by(&write_key/1)
      |> Map.new(fn {key, of_write} -> {key, write_state(List.last(of_write), ended?)} end)

    rows
    |> Enum.group_by(&{&1.system, &1.path})
    |> Enum.map(fn {{system, path}, [first | _] = of_place} ->
      written =
        of_place
        |> Enum.map(&Map.fetch!(states, write_key(&1)))
        |> written()

      {first.sequence,
       %{system: system, path: path, target_id: first.target_id, written: written}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The entries of `writes/2` whose place is one of the run's targets: its target
  (`target_system` and `target_path`) and the further paths in that system its label
  `paths_label` lists, comma-separated. `paths_label` is the label
  `Apiary.Lingo.Domain.paths_label/1` returns, nil for none. A write to any other place,
  such as a path the gateway kept as sent, has no entry: its place is not a name of the
  run's.
  None for a run with no target.
  """
  @spec of_run_targets([map], Run.t(), String.t() | nil) :: [map]
  def of_run_targets(writes, %Run{target_system: system, target_path: path} = run, paths_label)
      when is_binary(system) and is_binary(path) do
    further =
      case paths_label && run.labels[paths_label] do
        paths when is_binary(paths) -> String.split(paths, ",", trim: true)
        _none -> []
      end

    places = MapSet.new([path | further], &{system, &1})
    Enum.filter(writes, &MapSet.member?(places, {&1.system, &1.path}))
  end

  def of_run_targets(_writes, %Run{}, _paths_label), do: []

  defp write_key(%{request_id: id}) when is_binary(id), do: {:request, id}
  defp write_key(%{sequence: sequence}), do: {:row, sequence}

  defp write_state(%{state: "started"}, true), do: "cut"
  defp write_state(%{state: state}, _ended?), do: state

  defp written(states) do
    cond do
      "changed" in states -> :changed
      Enum.any?(states, &(&1 in ["started", "cut"])) -> :maybe
      true -> :refused
    end
  end
end

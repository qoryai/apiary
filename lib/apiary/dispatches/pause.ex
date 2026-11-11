defmodule Apiary.Dispatches.Pause do
  @moduledoc false

  # A paused run as the pages show it (`ApiaryWeb.PauseWords`): a registered run that its
  # gateway ended at its model keys' limit (`Apiary.Runs.Run.paused?/1`), and the run that
  # continues it (`Apiary.Dispatches.requeue_for_pause/2`).
  #
  # `of/1` is, for each paused run of `run_ids` (`runs.id`) whose provider is known and
  # that a continuation continues, `%{provider: name, until: time | nil, number: n,
  # workspace_id: id}`: the name of the run's model provider; when every key of that
  # provider was in cooldown as the run ended, the earliest end of those cooldowns
  # (`dispatch_runs.paused_until`), else nil; and the continuation's run number and
  # workspace. Any other run is not in the map. `of_public_ids/1` is the same by the runs'
  # public ids (`rn_…`).

  import Ecto.Query, only: [from: 2]

  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @type t :: %{
          provider: String.t(),
          until: DateTime.t() | nil,
          number: pos_integer,
          workspace_id: Ecto.UUID.t()
        }

  @spec of([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => t}
  def of(run_ids) when is_list(run_ids), do: read(:id, run_ids)

  @spec of_public_ids([String.t()]) :: %{optional(String.t()) => t}
  def of_public_ids(public_ids) when is_list(public_ids), do: read(:public_id, public_ids)

  defp read(_key, []), do: %{}

  defp read(key, values) do
    Repo.all(
      from r in Run,
        join: d in DispatchRun,
        on: d.id == r.dispatch_run_id,
        join: c in DispatchRun,
        on: c.continues_id == d.id,
        join: next in Run,
        on: next.dispatch_run_id == c.id,
        join: p in Connection,
        on: p.id == r.provider_connection_id,
        where: field(r, ^key) in ^Enum.uniq(values) and r.state == "paused",
        select:
          {field(r, ^key),
           %{
             provider: p.name,
             until: d.paused_until,
             number: next.number,
             workspace_id: next.workspace_id
           }}
    )
    |> Map.new()
  end

  @doc false
  @spec of_run(Run.t() | nil) :: t | nil
  def of_run(%Run{id: id, state: "paused"}), do: Map.get(of([id]), id)
  def of_run(_run), do: nil
end

defmodule Apiary.Runs.Place do
  @moduledoc """
  Where a run ran, in a query, as the pages show it (`ApiaryWeb.RunComponents.place_of/1`):
  for a run a node pool's dispatch handed over (`dispatch_run_id` set), the name of the
  pool, the run's node; for every other run, the host its `run.started` reported. The
  host of a pool's run is a machine of the pool's operator, which the runs list's Filter,
  a target's Machines and a key's hosts leave out.
  """

  @doc """
  shown_host/1 is the place of the run bound to `run` in a query, as text: the pool's name
  for a pool's run, read by a subquery on the run's node; else the run's `host`. NULL for
  a pool's run whose node is not a pool, and for a run without a host.
  """
  defmacro shown_host(run) do
    quote do
      type(
        fragment(
          "CASE WHEN ? IS NULL THEN ? ELSE (SELECT pn.name FROM nodes AS pn WHERE pn.id = ? AND pn.kind = 'pool') END",
          unquote(run).dispatch_run_id,
          unquote(run).host,
          unquote(run).node_id
        ),
        :string
      )
    end
  end
end

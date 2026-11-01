defmodule ApiaryWeb.RunAddress do
  @moduledoc false
  # A console address of a run ends in the run's number, `/:org/:workspace/runs/:number`
  # and the addresses under it. An address asked by the run's `rn_` id, the one the API
  # gives, is sent on to the same address with the number.

  alias Apiary.Runs.Run

  # numbered/3 is `:numbered` when `run_id`, the segment the request's path asked `run`
  # by, is the run's number; else `{:redirect, path}`, the request's path and query with
  # the number in that segment's place.
  @doc false
  @spec numbered(Plug.Conn.t(), String.t(), Run.t()) :: :numbered | {:redirect, String.t()}
  def numbered(%Plug.Conn{} = conn, run_id, %Run{number: number}) do
    if run_id == Integer.to_string(number) do
      :numbered
    else
      [before, rest] = String.split(conn.request_path, "/runs/" <> run_id, parts: 2)
      path = before <> "/runs/#{number}" <> rest

      {:redirect, if(conn.query_string == "", do: path, else: path <> "?" <> conn.query_string)}
    end
  end
end

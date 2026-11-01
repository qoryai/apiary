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
  def numbered(%Plug.Conn{} = conn, run_id, %Run{number: number} = run) do
    if run_id == Integer.to_string(number) do
      :numbered
    else
      # `path_info` is the path split at `/`, still percent-encoded.
      segments = Enum.map(conn.path_info, &URI.decode/1)
      {:redirect, renumber(segments, conn.query_string, run_id, run)}
    end
  end

  # renumber/4 is the address of the route segments `segments`, decoded as the router
  # matched them, with the run's number in place of the segment after `runs` that is
  # `run_id`, and the query `query` after it. Each segment is percent-encoded again, so a
  # run asked by `rn%5F…` is sent on as well.
  @doc false
  @spec renumber([String.t()], String.t() | nil, String.t(), Run.t()) :: String.t()
  def renumber(segments, query, run_id, %Run{number: number}) do
    {segments, _last} =
      Enum.map_reduce(segments, nil, fn segment, before ->
        if before == "runs" and segment == run_id,
          do: {Integer.to_string(number), segment},
          else: {segment, segment}
      end)

    path =
      "/" <>
        Enum.map_join(segments, "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

    if query in [nil, ""], do: path, else: path <> "?" <> query
  end
end

defmodule ApiaryWeb.RunLogController do
  @moduledoc """
  The raw log of a run: the decoded bytes of its log chunks after a sequence, in sequence
  order, as the runtime wrote them. Not a page. The terminal of the run page reads it, and
  so does "Download the raw bytes".

      GET /workspace/runs/:run_id/log?after=<sequence>&limit=<chunks>&stream=<name>&download=1

  `after` defaults to 0 and `limit` to 2,000 chunks (at most 10,000); `stream` keeps one of
  `terminal`, `stdout` and `stderr`; `download=1` sends every chunk as an attachment. The
  answer is `application/octet-stream`, chunked, and `x-qory-log-through` names the
  sequence the answer reaches, or `after` again when nothing followed: the reader asks
  again from there. A parameter that is not what it should be is a `400`.

  A run on a pseudo-terminal whose record says its size is answered at that size: the
  bytes of one answer were all written to a terminal of `x-qory-log-size`, `<cols>x<rows>`,
  the size in force right after `after`. An answer stops short of the next
  `dev.qory.run.resized`, and once every chunk before it is sent `x-qory-log-through` is
  the resize's own sequence, so the reader's next question is answered at the new size.
  No header on a run on pipes, on a single stream of pipes and on a download, which is every chunk whatever the size.

  Scoped like the page: the run is looked up in the signed-in user's workspace, and a run
  of another workspace is `404`, like one that does not exist. The bytes are never
  rendered by the server; `nosniff` and the attachment type keep a browser from rendering
  them either.

  The log is the record, so it belongs to `observability`, which every instance has.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  alias Apiary.Organisations
  alias Apiary.Runs.Record

  @streams ~w(terminal stdout stderr)

  def show(conn, %{"run_id" => run_id} = params) do
    with {:ok, scope} <- scope(conn),
         {:ok, run} <- Record.fetch_run(scope, run_id),
         {:ok, opts} <- options(params) do
      send_log(conn, scope, run, opts)
    else
      :error -> send_plain(conn, 404, gettext("not found"))
      {:error, :bad_request} -> send_plain(conn, 400, gettext("bad request"))
    end
  end

  defp scope(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{}} = scope ->
        case Organisations.load_scope(scope, get_session(conn, "organisation_id")) do
          %{organisation: %{}, workspace: %{}} = scope -> {:ok, scope}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp options(params) do
    with {:ok, after_sequence} <- integer(params["after"], 0),
         {:ok, limit} <- integer(params["limit"], nil),
         {:ok, stream} <- stream(params["stream"]) do
      download? = params["download"] == "1"

      {:ok,
       %{
         after: after_sequence,
         limit: if(download?, do: :all, else: limit),
         stream: stream,
         download?: download?
       }}
    end
  end

  defp integer(nil, default), do: {:ok, default}

  defp integer(value, _default) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_request}
    end
  end

  defp integer(_value, _default), do: {:error, :bad_request}

  defp stream(nil), do: {:ok, nil}
  defp stream(stream) when stream in @streams, do: {:ok, stream}
  defp stream(_other), do: {:error, :bad_request}

  defp send_log(conn, scope, run, opts) do
    read = [stream: opts.stream, limit: opts.limit]
    sized? = sized?(run, opts)
    resize = if sized?, do: Record.next_resize(scope, run, opts.after)

    {through, all?} =
      Record.log_through(scope, run, opts.after, read ++ [before: resize && resize.sequence])

    through = if resize && all?, do: resize.sequence, else: through
    size = if sized?, do: Record.terminal_size(scope, run, opts.after)

    conn =
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-qory-log-through", Integer.to_string(through))
      |> size_header(size)
      |> disposition(run, opts)
      |> send_chunked(200)

    Record.log_pages(
      scope,
      run,
      opts.after,
      through,
      conn,
      fn bytes, conn ->
        case chunk(conn, bytes) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end,
      read
    )
  end

  # The record says a size, and the answer is the terminal's stream, read to be replayed.
  defp sized?(run, opts) do
    is_integer(run.terminal_cols) and not opts.download? and opts.stream in [nil, "terminal"]
  end

  defp size_header(conn, {cols, rows}),
    do: put_resp_header(conn, "x-qory-log-size", "#{cols}x#{rows}")

  defp size_header(conn, nil), do: conn

  # The file name is made of the first eight characters of a UUID the database matched.
  defp disposition(conn, run, %{download?: true}) do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(attachment; filename="#{String.slice(run.run_id, 0, 8)}.log")
    )
  end

  defp disposition(conn, _run, _opts), do: conn

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end

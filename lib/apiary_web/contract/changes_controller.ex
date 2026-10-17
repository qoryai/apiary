defmodule ApiaryWeb.Contract.ChangesController do
  @moduledoc false

  # `GET /v1/work-items/changes?after=<cursor>`, the adapter's read of its change feed
  # (the integration contract's `changes.schema.json`, `Apiary.Adapters.Feed`). Reached
  # only through `ApiaryWeb.Contract.AdapterRequest`, which verifies the request under the
  # adapter's access key with its `X-Qory-Timestamp`, refuses what comes before the
  # request is read (`400` `bad_request`, `401`, `429`, `400`
  # `unsupported_contract_version`, then `401` for a stale timestamp or a replay), and
  # signs every answer but a `401`.
  #
  # Then, in order:
  #
  #   1. a query other than none or exactly `after=<cursor>`, a cursor as the feed writes
  #      it (`Apiary.Adapters.Feed.parse_cursor/1`), is `400` `invalid_request`;
  #   2. a key `Apiary.Access` does not let read the feed (`work_item.read_changes`) is
  #      `403` `forbidden`, decided from the key and the action alone; `404` `not_found`
  #      where its adapter is not found to it;
  #   3. a cursor past the last entry of the adapter's feed, one this feed never gave, is
  #      `400` `invalid_request`;
  #   4. else the answer is `200`, signed: `{version: 1, revision, cursor, changes}`, the
  #      entries of the key's adapter's feed after the cursor, at most a page of them
  #      (`Apiary.Adapters.Feed.page_size/0`), in order, those of a kind the revision the
  #      request named (`X-Qory-Contract-Version`) does not define left out, and the
  #      cursor where the page ends, past any entry left out. A request with no `after`
  #      reads from the start. While the feed has no entry after the cursor, the request is held, up
  #      to 25 seconds, the feed read again every second, and answered as soon as one
  #      commits, else with no changes and the same cursor. `revision` is the request's
  #      revision, inside the signed body.
  #
  # The GET names no connection and no organisation: the feed is the adapter's, one log
  # for all its connections, as the contract has it, and a key reads only the feed of its
  # adapter. When the answer cannot be read, it is `503` `unavailable`. Nothing here logs a
  # header, the query or a signature.
  #
  # How long it holds and how often it reads again are `hold` and `poll`, in milliseconds,
  # of `config :apiary, ApiaryWeb.Contract.ChangesController`, 25,000 and 1,000 unless
  # set.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters
  alias Apiary.Adapters.Feed

  @hold 25_000
  @poll 1_000
  # The longest cursor the feed writes; a longer one is refused before it is read.
  @max_cursor 20

  @doc false
  def index(conn, _params) do
    with {:ok, after_seq} <- after_cursor(conn.query_string),
         scope = Scope.for_access_key(conn.assigns.access_key),
         {:ok, adapter} <- Adapters.for_key(scope, :"work_item.read_changes"),
         revision = conn.assigns.contract_version,
         {:ok, page} <- hold(adapter, after_seq, revision) do
      answer(conn, revision, page)
    else
      :error -> refuse(conn, 400, "invalid_request")
      {:error, :stale} -> refuse(conn, 400, "invalid_request")
      {:error, :forbidden} -> refuse(conn, 403, "forbidden")
      {:error, :not_found} -> refuse(conn, 404, "not_found")
    end
  rescue
    exception ->
      Logger.error("an adapter's change feed could not be read: #{inspect(exception.__struct__)}")

      refuse(conn, 503, "unavailable")
  end

  # The cursor the query names: none reads from the start; `after=` and a cursor as the
  # feed writes it, alone, reads after it. Anything else, `after` twice, empty, longer than
  # any cursor or percent-encoded, or another parameter, is refused.
  defp after_cursor(""), do: {:ok, 0}

  defp after_cursor("after=" <> cursor) when byte_size(cursor) <= @max_cursor,
    do: Feed.parse_cursor(cursor)

  defp after_cursor(_query), do: :error

  defp hold(adapter, after_seq, revision) do
    settings = Application.get_env(:apiary, __MODULE__, [])
    deadline = now() + Keyword.get(settings, :hold, @hold)
    poll(adapter, after_seq, revision, deadline, Keyword.get(settings, :poll, @poll))
  end

  # A page that ends where it started holds nothing: read again until one does, or the
  # deadline passes.
  defp poll(adapter, after_seq, revision, deadline, every) do
    case Feed.read(adapter, after_seq, revision) do
      {:ok, %{seq: ^after_seq}} = nothing ->
        case deadline - now() do
          left when left > 0 ->
            Process.sleep(min(every, left))
            poll(adapter, after_seq, revision, deadline, every)

          _passed ->
            nothing
        end

      other ->
        other
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp answer(conn, revision, %{seq: seq, changes: changes}) do
    body =
      Jason.encode!(
        Jason.OrderedObject.new([
          {"version", 1},
          {"revision", revision},
          {"cursor", Feed.cursor(seq)},
          {"changes", changes}
        ])
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp refuse(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end

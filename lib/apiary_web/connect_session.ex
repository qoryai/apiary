defmodule ApiaryWeb.ConnectSession do
  # The nonces of the connect passes a person's browser started, kept in their session,
  # by the connection's public id (`ac_…`): `put/3` when they press Install
  # (`Apiary.Adapters.connect/2` gives what to keep), `fetch/2` and `drop/2` when they
  # come back with the adapter's return (`ApiaryWeb.AdapterRedirectController`). A return
  # is taken only in the browser whose session kept its nonce
  # (`Apiary.Adapters.Connections.complete_return/4`).
  #
  # Beside a nonce, the session may keep where the return leads (`back/2`): a word that
  # `back?/1` takes, such as "set-up:sources:workspace=ws_0000000000000000" for an install
  # started at the Work sources step of that workspace's set-up, never an address. The
  # workspace is named by its public id (`ws_…`), which a rename keeps, so a rename
  # between Install and the return does not lose it. Neither the
  # pass nor the adapter's return link contains it.
  #
  # The session keeps the last `kept/0` connections a browser started, the latest pass of
  # each: a new pass for the same connection replaces the one kept.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Plug.Conn, only: [get_session: 2, put_session: 3]

  alias Apiary.Lingo.Domain

  @key "connect_passes"
  @kept 4
  @pages ~w(set-up new-workspace)
  @steps ~w(sources destinations)

  # How many connections a session keeps a nonce for.
  @doc false
  @spec kept() :: pos_integer
  def kept, do: @kept

  # Whether `back` is a place a return may lead to, besides the integration's page: a step
  # of the workspace set-up that connects, `<page>:<step>`, `<page>:<step>:<type>` before
  # the workspace exists, or `<page>:<step>:workspace=<id>` once it does. The page is
  # "set-up" (`/:org/:workspace/set-up/<step>`) or "new-workspace", the step
  # "sources" or "destinations", the type a domain's name (`Apiary.Lingo.Domain`), and
  # the id a workspace's public id in form (`ws_…`); the install checks it against the
  # organisation's workspaces (`back_workspace/1`). "set-up" alone is the set-up's Work sources step.
  @doc false
  @spec back?(term) :: boolean
  def back?("set-up"), do: true

  def back?(back) when is_binary(back) do
    case String.split(back, ":") do
      [page, step] ->
        page in @pages and step in @steps

      [page, step, "workspace=" <> id] ->
        page in @pages and step in @steps and Apiary.PublicId.valid?("ws", id)

      [page, step, type] ->
        page in @pages and step in @steps and type in Domain.names()

      _other ->
        false
    end
  end

  def back?(_back), do: false

  # The public id of the workspace `back` leads to (`back?/1`), nil for a `back` with none.
  @doc false
  @spec back_workspace(term) :: String.t() | nil
  def back_workspace(back) when is_binary(back) do
    case String.split(back, ":") do
      [_page, _step, "workspace=" <> id] -> id
      _other -> nil
    end
  end

  def back_workspace(_back), do: nil

  # Keeps `nonce` (base64url) for the connection `connection_id` in the session of `conn`,
  # the session's latest, in place of any kept for it before, with `back` beside it where
  # `back?/1` takes it; any other `back` is not kept.
  @doc false
  @spec put(Plug.Conn.t(), {String.t(), String.t()}, term) :: Plug.Conn.t()
  def put(conn, {connection_id, nonce}, back \\ nil)
      when is_binary(connection_id) and is_binary(nonce) do
    entry = if back?(back), do: [connection_id, nonce, back], else: [connection_id, nonce]

    kept =
      [entry | Enum.reject(entries(conn), &(hd(&1) == connection_id))]
      |> Enum.take(@kept)

    put_session(conn, @key, kept)
  end

  # The nonce the session of `conn` keeps for the connection `connection_id`, or nil.
  @doc false
  @spec fetch(Plug.Conn.t(), term) :: String.t() | nil
  def fetch(conn, connection_id) do
    Enum.find_value(entries(conn), fn
      [^connection_id, nonce | _back] -> nonce
      _other -> nil
    end)
  end

  # Where the return of the connection `connection_id` leads, as the session of `conn`
  # keeps it beside the nonce: a word `back?/1` takes, or nil for the integration's page.
  @doc false
  @spec back(Plug.Conn.t(), term) :: String.t() | nil
  def back(conn, connection_id) do
    Enum.find_value(entries(conn), fn
      [^connection_id, _nonce, back] -> back
      _other -> nil
    end)
  end

  # The session of `conn` without the nonce it kept for `connection_id`.
  @doc false
  @spec drop(Plug.Conn.t(), term) :: Plug.Conn.t()
  def drop(conn, connection_id) do
    case Enum.reject(entries(conn), &(hd(&1) == connection_id)) do
      [] -> Plug.Conn.delete_session(conn, @key)
      kept -> put_session(conn, @key, kept)
    end
  end

  # What the session keeps, read as it should be: a list of `[connection_id, nonce]`, or
  # `[connection_id, nonce, back]` with `back` a word `back?/1` takes. A `back` it no
  # longer takes, such as one with a workspace's slug kept before the workspace was named
  # by its public id, is dropped and the nonce kept, so the return is still taken and
  # leads to the integration's page.
  defp entries(conn) do
    case get_session(conn, @key) do
      list when is_list(list) ->
        Enum.flat_map(list, fn
          [id, nonce] = entry when is_binary(id) and is_binary(nonce) ->
            [entry]

          [id, nonce, back] = entry when is_binary(id) and is_binary(nonce) ->
            if back?(back), do: [entry], else: [[id, nonce]]

          _other ->
            []
        end)

      _other ->
        []
    end
  end
end

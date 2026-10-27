defmodule ApiaryWeb.ConnectSession do
  # The nonces of the connect passes a person's browser started, kept in their session,
  # by the connection's public id (`ac_…`): `put/3` when they press Install
  # (`Apiary.Adapters.connect/2` gives what to keep), `fetch/2` and `drop/2` when they
  # come back with the adapter's return (`ApiaryWeb.AdapterRedirectController`). A return
  # is taken only in the browser whose session kept its nonce
  # (`Apiary.Adapters.Connections.complete_return/4`).
  #
  # Beside a nonce, the session may keep where the return leads (`back/2`): one of
  # `backs/0`, such as "set-up" for an install started at the workspace set-up's Work
  # source step, never an address. Neither the pass nor the adapter's return link
  # carries it.
  #
  # The session keeps the last `kept/0` connections a browser started, the latest pass of
  # each: a new pass for the same connection replaces the one kept.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Plug.Conn, only: [get_session: 2, put_session: 3]

  @key "connect_passes"
  @kept 4
  @backs ~w(set-up)

  # How many connections a session keeps a nonce for.
  @doc false
  @spec kept() :: pos_integer
  def kept, do: @kept

  # Where a return may lead, besides the integration's page: "set-up", the workspace
  # set-up's Work source step.
  @doc false
  @spec backs() :: [String.t()]
  def backs, do: @backs

  # Keeps `nonce` (base64url) for the connection `connection_id` in the session of `conn`,
  # the session's latest, in place of any kept for it before, with `back` beside it where
  # it is one of `backs/0`; any other `back` is not kept.
  @doc false
  @spec put(Plug.Conn.t(), {String.t(), String.t()}, term) :: Plug.Conn.t()
  def put(conn, {connection_id, nonce}, back \\ nil)
      when is_binary(connection_id) and is_binary(nonce) do
    entry = if back in @backs, do: [connection_id, nonce, back], else: [connection_id, nonce]

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
  # keeps it beside the nonce: one of `backs/0`, or nil for the integration's page.
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
  # `[connection_id, nonce, back]` with `back` one of `backs/0`.
  defp entries(conn) do
    case get_session(conn, @key) do
      list when is_list(list) ->
        Enum.filter(list, fn
          [id, nonce] -> is_binary(id) and is_binary(nonce)
          [id, nonce, back] -> is_binary(id) and is_binary(nonce) and back in @backs
          _other -> false
        end)

      _other ->
        []
    end
  end
end

defmodule ApiaryWeb.ConnectSession do
  # The nonces of the connect passes a person's browser started, kept in their session,
  # by the connection's public id (`ac_…`): `put/2` when they press Install
  # (`Apiary.Adapters.connect/2` gives what to keep), `fetch/2` and `drop/2` when they
  # come back with the adapter's return (`ApiaryWeb.AdapterRedirectController`). A return
  # is taken only in the browser whose session kept its nonce
  # (`Apiary.Adapters.Connections.complete_return/4`).
  #
  # The session keeps the last `kept/0` connections a browser started, the latest pass of
  # each: a new pass for the same connection replaces the one kept.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Plug.Conn, only: [get_session: 2, put_session: 3]

  @key "connect_passes"
  @kept 4

  # How many connections a session keeps a nonce for.
  @doc false
  @spec kept() :: pos_integer
  def kept, do: @kept

  # Keeps `nonce` (base64url) for the connection `connection_id` in the session of `conn`,
  # the session's latest, in place of any kept for it before.
  @doc false
  @spec put(Plug.Conn.t(), {String.t(), String.t()}) :: Plug.Conn.t()
  def put(conn, {connection_id, nonce}) when is_binary(connection_id) and is_binary(nonce) do
    kept =
      [[connection_id, nonce] | Enum.reject(entries(conn), &match?([^connection_id, _], &1))]
      |> Enum.take(@kept)

    put_session(conn, @key, kept)
  end

  # The nonce the session of `conn` keeps for the connection `connection_id`, or nil.
  @doc false
  @spec fetch(Plug.Conn.t(), term) :: String.t() | nil
  def fetch(conn, connection_id) do
    Enum.find_value(entries(conn), fn
      [^connection_id, nonce] -> nonce
      _other -> nil
    end)
  end

  # The session of `conn` without the nonce it kept for `connection_id`.
  @doc false
  @spec drop(Plug.Conn.t(), term) :: Plug.Conn.t()
  def drop(conn, connection_id) do
    case Enum.reject(entries(conn), &match?([^connection_id, _], &1)) do
      [] -> Plug.Conn.delete_session(conn, @key)
      kept -> put_session(conn, @key, kept)
    end
  end

  # What the session keeps, read as it should be: a list of `[connection_id, nonce]`.
  defp entries(conn) do
    case get_session(conn, @key) do
      list when is_list(list) ->
        Enum.filter(list, &match?([id, nonce] when is_binary(id) and is_binary(nonce), &1))

      _other ->
        []
    end
  end
end

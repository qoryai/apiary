defmodule ApiaryWeb.Contract.ContractVersion do
  @moduledoc """
  ContractVersion decides whether a request names a revision of runner contract v1 this
  server serves, for every endpoint of the contract: discovery, the events endpoint and
  the run configuration.

  The runner sends `X-Qory-Contract-Version`, the revision it implements, on every
  request. The header is served when it is sent once, is a decimal integer and is one of
  `supported/0`, which is `[1]`; anything else, the header absent or sent twice included,
  is refused with `400` and `{"error":"unsupported_contract_version","supported":[1]}`.

  A controller calls `fetch/1` once the request has verified, so a request that does not
  is `401` whatever its header says, and answers a refusal with `refuse/1`. Where the
  check falls among an endpoint's other refusals is the controller's to say.
  """

  import Plug.Conn

  @supported [1]

  @doc "supported/0 lists the revisions of contract v1 this server serves."
  @spec supported() :: [pos_integer()]
  def supported, do: @supported

  @doc """
  fetch/1 returns `{:ok, revision}` when `X-Qory-Contract-Version` is sent once and is a
  revision served, and `:error` otherwise.
  """
  @spec fetch(Plug.Conn.t()) :: {:ok, pos_integer()} | :error
  def fetch(conn) do
    with [value] <- get_req_header(conn, "x-qory-contract-version"),
         {version, ""} <- Integer.parse(value),
         true <- version in @supported do
      {:ok, version}
    else
      _ -> :error
    end
  end

  @doc "refuse/1 answers `400` with the error and the revisions served."
  @spec refuse(Plug.Conn.t()) :: Plug.Conn.t()
  def refuse(conn) do
    conn
    |> put_status(400)
    |> Phoenix.Controller.json(%{error: "unsupported_contract_version", supported: @supported})
  end
end

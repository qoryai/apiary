defmodule Apiary.Contract.Signature do
  @moduledoc """
  The signature of a signed GET in the server contract.

  A GET has no body, so the runner signs a canonical string of the method, the
  path with its query and a timestamp, with HMAC SHA-256 keyed by the access
  key's secret. Pure functions; nothing here touches the database or logs.
  """

  @prefix "sha256="

  @doc ~S"""
  The canonical string: `"METHOD\npath?query\ntimestamp"`.
  """
  def canonical_string(method, path_with_query, timestamp)
      when is_binary(method) and is_binary(path_with_query) do
    "#{String.upcase(method)}\n#{path_with_query}\n#{timestamp}"
  end

  @doc "`sha256=` followed by the lowercase hex HMAC SHA-256 of `canonical` keyed with `secret`."
  def sign(secret, canonical) when is_binary(secret) and is_binary(canonical) do
    @prefix <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, canonical), case: :lower)
  end

  @doc """
  Whether `header_value` is the signature of `canonical` under any of `secrets`.

  Every secret is compared in constant time and every comparison runs, whether
  or not an earlier one matched. Anything but a binary header value is false.
  """
  def verify(secrets, canonical, header_value)
      when is_list(secrets) and is_binary(header_value) do
    Enum.reduce(secrets, false, fn secret, matched ->
      match = Plug.Crypto.secure_compare(sign(secret, canonical), header_value)
      matched or match
    end)
  end

  def verify(_secrets, _canonical, _header_value), do: false
end

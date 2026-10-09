defmodule Apiary.Kinds.Headers do
  @moduledoc """
  Headers answers whether a service may set its secret in a header: `auth.header` of a
  service definition, and of a runtime's declaration, is an RFC 9110 field name of at most
  64 characters that the list here does not refuse, compared in lower case;
  `authorization` is reached through the `bearer` and `basic` schemes alone.

  The list refuses the connection's own fields, the names hosts commonly send back or log
  beside a request, and every name that starts with one of the refused prefixes.
  """

  @field_name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}\z/

  @refused ~w(
    authorization connection content-length content-type cookie forwarded host keep-alive
    origin range referer te trailer transfer-encoding upgrade user-agent via
    x-correlation-id x-request-id
  )

  @refused_prefixes ~w(accept if- x-forwarded- proxy- sec- x-qory- qory-)

  @doc "refused?/1 says whether a service may not set its secret in the header `name`."
  @spec refused?(String.t()) :: boolean
  def refused?(name) when is_binary(name) do
    lower = String.downcase(name)

    not Regex.match?(@field_name, name) or lower in @refused or
      Enum.any?(@refused_prefixes, &String.starts_with?(lower, &1))
  end
end

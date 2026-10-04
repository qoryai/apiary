defmodule Apiary.Kinds.Hosts do
  @moduledoc """
  Hosts holds the contracts' rules on host names that the kinds share.

  An **exact host** is a lower-case DNS name with at least one dot whose last label
  starts with a letter: no IP literal, no port, no bare name. A **host pattern**, in the
  grammar of an integration's `hosts` and `serves` and of the policy's allow list, is an
  exact host, or `*.` and one, which covers every host below it and not the name itself.

  The names `localhost`, and any that ends in `.localhost`, `.local`, `.internal` or
  `.home.arpa`, are refused wherever a host is saved: they name no host of the internet.
  """

  @exact ~r/\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @refused_suffixes ~w(.localhost .local .internal .home.arpa)

  @doc "exact?/1 says whether `host` is an exact host (see the module's documentation)."
  @spec exact?(term) :: boolean
  def exact?(host) when is_binary(host), do: byte_size(host) <= 253 and Regex.match?(@exact, host)
  def exact?(_host), do: false

  @doc "refused_name?/1 says whether `host` is a name refused wherever a host is saved."
  @spec refused_name?(String.t()) :: boolean
  def refused_name?(host) when is_binary(host) do
    host = String.downcase(host)
    host == "localhost" or Enum.any?(@refused_suffixes, &String.ends_with?(host, &1))
  end

  @doc """
  covers?/2 says whether the host pattern `pattern` covers the host or pattern `host`:
  the same name, or `*.name` over a name below `name`, a pattern included.
  """
  @spec covers?(String.t(), String.t()) :: boolean
  def covers?(pattern, host) when is_binary(pattern) and is_binary(host) do
    case pattern do
      "*." <> base -> host != base and String.ends_with?(host, "." <> base)
      exact -> exact == host
    end
  end

  @doc "overlap?/2 says whether two host patterns cover a host in common."
  @spec overlap?(String.t(), String.t()) :: boolean
  def overlap?(a, b), do: a == b or covers?(a, b) or covers?(b, a)
end

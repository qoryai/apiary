defmodule Apiary.Kinds.Endpoint do
  @moduledoc """
  Endpoint is the rule for an address that a person enters for an integration's API, such
  as a LiteLLM provider's address, and for any `default` a description gives such a
  setting. The integrations contract does not check a setting's value, so Qory Apiary
  checks it here before it stores the value, and again before a run is sent to it.

  An address passes when it follows the contract's `endpoint_url` definition
  (`priv/contract/integration/definitions.schema.json`): at most 2,048 characters,
  `https://`, a host of lower-case labels joined by dots, each label 1 to 63 letters,
  digits and hyphens that starts and ends with a letter or a digit, an optional port from 1
  to 65535 with no leading zero, and an optional path of letters, digits,
  `-._~!$&'()*+,;=:@/` and percent-encodings, with no user information, query or fragment.
  An IPv6 address has no form in that host grammar, so `::1` and `fe80::/10` never pass.

  It also refuses the hosts the contract's `egress_host` definition keeps out of a
  description: a single label, a localhost name (`localhost`, `localhost4` or
  `localhost6`, alone or with `.localdomain`, `.localdomain4` or `.localdomain6`, or a
  host under one), an IPv4 address in 127.0.0.0/8, 169.254.0.0/16 or 0.0.0.0/8, and a
  number in any form other than a canonical IPv4 address. A host is a number when its last
  label is all digits, or `0x` and hex digits or none. Private addresses, such as
  10.0.0.12, pass: a self-hosted gateway may reach them.

  `check/1` returns the first rule an address breaks, as a message of the `errors` domain
  and its bindings, which a changeset takes as an error.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  @max_length 2048

  @label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @port ~r/\A(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])\z/
  @path_character ~r/\A[A-Za-z0-9._~!$&'()*+,;=:@\/-]\z/
  @hex ~r/\A[0-9A-Fa-f]{2}\z/
  @localhost ~r/\A(?:.+\.)?localhost[46]?(?:\.localdomain[46]?)?\z/
  @number ~r/\A(?:[0-9]+|0x[0-9a-f]*)\z/
  @part ~r/\A(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\z/

  # The IPv4 ranges a run may not reach, as `{first part, second part or nil, range}`.
  @refused_ranges [
    {"127", nil, "127.0.0.0/8"},
    {"169", "254", "169.254.0.0/16"},
    {"0", nil, "0.0.0.0/8"}
  ]

  @typedoc "A refusal: a message of the `errors` domain, and its bindings."
  @type refusal :: {String.t(), keyword}

  @doc "The most characters an address has."
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  @doc """
  check/1 checks `address` against the rules of the module's documentation: `:ok`, or
  `{:error, {message, bindings}}` for the first rule it breaks, in this order: its length,
  the scheme, user information, a query or fragment, the host's form, the host's rules,
  the port, then the path.
  """
  @spec check(term) :: :ok | {:error, refusal}
  def check(address) when is_binary(address) do
    # An invalid byte becomes U+FFFD, which no rule lets pass, and which a message can show.
    address = String.replace_invalid(address)

    with :ok <- length_rule(address),
         {:ok, rest} <- scheme_rule(address),
         {authority, path} = split_authority(rest),
         :ok <- user_rule(authority),
         :ok <- query_rule(path),
         {:ok, host, port} <- host_and_port(authority),
         :ok <- host_rule(host),
         :ok <- port_rule(port) do
      path_rule(path)
    end
  end

  def check(_address), do: {:error, scheme()}

  @doc """
  host/1 is the host of an address that passes `check/1`: `{:ok, host}`, or `:error` for
  an address that does not pass.
  """
  @spec host(term) :: {:ok, String.t()} | :error
  def host(address) do
    with :ok <- check(address),
         "https://" <> rest <- address,
         {authority, _path} = split_authority(rest),
         [host | _port] <- String.split(authority, ":", parts: 2) do
      {:ok, host}
    else
      _ -> :error
    end
  end

  defp length_rule(address) do
    if String.length(address) > @max_length,
      do:
        {:error,
         {dgettext_noop("errors", "Shorten the address to at most 2,048 characters."), []}},
      else: :ok
  end

  defp scheme_rule("https://" <> rest), do: {:ok, rest}
  defp scheme_rule(_address), do: {:error, scheme()}

  defp scheme,
    do:
      {dgettext_noop(
         "errors",
         "Start the address with https://, such as https://models.example.com."
       ), []}

  # The authority ends at the first /, ? or #; the rest is the path, with any query or
  # fragment after it.
  defp split_authority(rest) do
    case :binary.match(rest, ["/", "?", "#"]) do
      {at, _length} -> {binary_part(rest, 0, at), binary_part(rest, at, byte_size(rest) - at)}
      :nomatch -> {rest, ""}
    end
  end

  defp user_rule(authority) do
    if String.contains?(authority, "@"),
      do:
        {:error,
         {dgettext_noop(
            "errors",
            "Remove the part before @ from the address. Enter the key among the provider's keys instead."
          ), []}},
      else: :ok
  end

  defp query_rule(path) do
    case :binary.match(path, ["?", "#"]) do
      {at, 1} ->
        {:error,
         {dgettext_noop(
            "errors",
            "Remove the %{character} and everything after it. The address takes a path, but no query or fragment."
          ), character: binary_part(path, at, 1)}}

      :nomatch ->
        :ok
    end
  end

  # One colon at most: more, or a bracket, is an IPv6 address, which the host grammar has
  # no form for.
  defp host_and_port(authority) do
    case String.split(authority, ":") do
      [host] when host != "" -> host_form(host, nil)
      [host, port] when host != "" -> host_form(host, port)
      _other -> {:error, host_form()}
    end
  end

  defp host_form(host, port) do
    lower = String.downcase(host)

    cond do
      labels?(host) ->
        {:ok, host, port}

      lower != host and labels?(lower) ->
        {:error, {dgettext_noop("errors", "Write the host in lower case: %{host}."), host: lower}}

      true ->
        {:error, host_form()}
    end
  end

  defp host_form,
    do:
      {dgettext_noop(
         "errors",
         "Write the host as labels of letters, digits and hyphens joined by dots, such as models.example.com."
       ), []}

  defp labels?(host), do: host |> String.split(".") |> Enum.all?(&Regex.match?(@label, &1))

  defp host_rule(host) do
    labels = String.split(host, ".")

    cond do
      length(labels) == 1 ->
        {:error,
         {dgettext_noop(
            "errors",
            "Enter the full host name, such as models.example.com. Runs may not reach a host without a dot."
          ), []}}

      Regex.match?(@localhost, host) ->
        {:error,
         {dgettext_noop(
            "errors",
            "Enter the host that runs reach over the network. %{host} is a name for the local machine."
          ), host: host}}

      Regex.match?(@number, List.last(labels)) ->
        address_rule(host, labels)

      true ->
        :ok
    end
  end

  defp address_rule(host, [first, second | _rest] = labels) do
    canonical? = length(labels) == 4 and Enum.all?(labels, &Regex.match?(@part, &1))

    case Enum.find(@refused_ranges, fn {a, b, _range} -> a == first and b in [nil, second] end) do
      _range when not canonical? ->
        {:error,
         {dgettext_noop(
            "errors",
            "Write the address as four numbers from 0 to 255 with dots between them and no leading zeros, such as 10.0.0.12."
          ), []}}

      {_a, _b, range} ->
        {:error,
         {dgettext_noop(
            "errors",
            "Enter another host. Runs may not reach %{host}: it is in %{range}."
          ), host: host, range: range}}

      nil ->
        :ok
    end
  end

  defp port_rule(nil), do: :ok

  defp port_rule(port) do
    if Regex.match?(@port, port),
      do: :ok,
      else:
        {:error,
         {dgettext_noop(
            "errors",
            "Write the port as a number from 1 to 65535, with no leading zero."
          ), []}}
  end

  defp path_rule(path), do: path |> String.graphemes() |> path_characters()

  defp path_characters([]), do: :ok

  defp path_characters(["%", a, b | rest]) do
    if Regex.match?(@hex, a <> b), do: path_characters(rest), else: bad_path_character("%")
  end

  defp path_characters([character | rest]) do
    if Regex.match?(@path_character, character),
      do: path_characters(rest),
      else: bad_path_character(character)
  end

  defp bad_path_character(character),
    do:
      {:error,
       {dgettext_noop("errors", "Percent-encode %{character} in the path, or remove it."),
        character: character}}
end

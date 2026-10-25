defmodule Apiary.Runs.RunCredentialIssue do
  @moduledoc """
  Checks an adapter's answer to the run-credential call against the run's credential
  entry, before Qory Apiary seals the credential to a gateway.

  `check/3` takes the entry, the decoded `credential` member of the answer
  (`run-credential-answer.schema.json` of the integration contract) and the time `now`.
  It returns `{:ok, issue}` when the answer stays inside the entry and the secret has a
  safe form, or `{:error, cause}`, where the cause is an atom of `causes/0`. It checks,
  in this order, and stops at the first refusal:

    1. The arguments: `now` is a `DateTime` in UTC (`:now_invalid`), the entry has the
       shape below (`:entry_invalid`), and the credential is a map (`:answer_invalid`).
    2. Every member of the credential and of each apply item is one that the Forager
       contract's `credential.schema.json` defines (`:unknown_member`), and `version`
       is 1 (`:version_unsupported`). The contract requires `version`, so an absent
       `version` is refused too.
    3. The credential has no `placeholders`, because placeholders come only from the run
       configuration (`:placeholders_present`).
    4. A top-level `token` is a string (`:token_missing`) of 1 to 16,384 bytes
       (`:token_size`) of valid UTF-8 (`:token_encoding`), with no control character but
       tab: no U+0000 to U+0008, U+000A to U+001F, U+007F or U+0080 to U+009F
       (`:token_control_character`), and no space or tab at its start or its end
       (`:token_padded`).
    5. `apply` is a list of 1 to 16 items (`:apply_invalid`), the maximum of the sealed
       plaintext's `apply` in the Forager contract. Each item is a map whose `hosts` are
       1 to 16 distinct strings, whose `scheme` is a string, whose `username` and
       `header` are strings when present, and whose `paths` are 1 to 32 distinct strings
       of the path grammar `^/[^*?#\\s]*\\*?$` when present (`:apply_item_invalid`). No
       item has a `token` (`:token_in_apply_item`).
    6. Each answer item lies inside one entry item: the same `scheme`, the same
       `username` and the same `header`, each both absent or equal
       (`:scheme_outside_entry`); every host among that entry item's hosts
       (`:host_outside_entry`); and, when the entry item has `paths`, answer `paths`
       that are each equal to an entry path, or under an entry path that ends in `*`
       (`:path_outside_entry`). "Under" means that the answer path starts with the entry
       path without its `*`. When the entry item has no `paths`, the answer item may
       have any paths or none. The comparison is exact: no case folding, no
       percent-decoding, and no trailing-slash or dot-segment normalisation. When no
       entry item matches the scheme, the cause is `:scheme_outside_entry`; when some
       match it and none contains the hosts, `:host_outside_entry`; otherwise
       `:path_outside_entry`.
    7. `expires_at`, when present, is an RFC 3339 date-time (`:expires_at_invalid`):
       `YYYY-MM-DD`, then `T` or `t`, then `hh:mm:ss`, then an optional fraction of
       one or more digits, then `Z`, `z` or an offset `+hh:mm` or `-hh:mm`, where
       `-00:00` means UTC. A space in place of `T` is refused. The fraction is cut to
       microseconds, which can only make the expiry earlier. A leap second (second
       60) is refused, because an Elixir `DateTime` has no value for second 60. The
       time is more than 6 minutes after `now` (`:expires_at_too_soon`) and at most
       24 hours after `now` (`:expires_at_too_late`). Absent means that the
       credential does not expire.

  The entry is a map with string keys: `"apply"`, a list of 1 to 16 apply items, each
  with `"hosts"` (a list of strings), `"scheme"` (`"bearer"`, `"basic"` or `"header"`)
  and optional `"username"`, `"header"` and `"paths"`, with the paths filled; and
  optional `"name"`, `"purpose"` and `"placeholders"`, a list of strings. This is the
  host credential of the run configuration, so a composed entry fits as it is.

  The module makes no call, reads no database and writes no log line or Activity entry.
  A refusal is an atom only: no cause contains the token or any part of the answer. The
  token is in the result's `value` field as a function of no arguments that returns it,
  so `inspect/2` shows no token, even with `structs: false`. Read it with `value/1`.
  Never write the struct to a database, a log or a term binary
  (`:erlang.term_to_binary/1` serialises the token with the function).
  """

  @derive {Inspect, except: [:value]}
  @enforce_keys [:value, :expires_at, :apply]
  defstruct [:value, :expires_at, :apply]

  @typedoc """
  A checked credential: `value` returns the token through `value/1`, `expires_at` is
  the expiry in UTC or nil for none, and `apply` contains the answer's apply items as
  the adapter sent them.
  """
  @type t :: %__MODULE__{
          value: (-> String.t()),
          expires_at: DateTime.t() | nil,
          apply: [%{required(String.t()) => term()}]
        }

  @typedoc "Why `check/3` refuses an answer. `causes/0` lists them in the order of the checks."
  @type cause ::
          :now_invalid
          | :entry_invalid
          | :answer_invalid
          | :unknown_member
          | :version_unsupported
          | :placeholders_present
          | :token_missing
          | :token_size
          | :token_encoding
          | :token_control_character
          | :token_padded
          | :apply_invalid
          | :apply_item_invalid
          | :token_in_apply_item
          | :scheme_outside_entry
          | :host_outside_entry
          | :path_outside_entry
          | :expires_at_invalid
          | :expires_at_too_soon
          | :expires_at_too_late

  @causes [
    :now_invalid,
    :entry_invalid,
    :answer_invalid,
    :unknown_member,
    :version_unsupported,
    :placeholders_present,
    :token_missing,
    :token_size,
    :token_encoding,
    :token_control_character,
    :token_padded,
    :apply_invalid,
    :apply_item_invalid,
    :token_in_apply_item,
    :scheme_outside_entry,
    :host_outside_entry,
    :path_outside_entry,
    :expires_at_invalid,
    :expires_at_too_soon,
    :expires_at_too_late
  ]

  # The members of `credential.schema.json` in the Forager contract.
  @members ["version", "token", "expires_at", "apply", "placeholders"]
  @item_members ["hosts", "scheme", "username", "header", "token", "paths"]

  # The members of a host credential and of its apply item in `run-configuration.schema.json`.
  @entry_members ["name", "purpose", "apply", "placeholders"]
  @entry_item_members ["hosts", "scheme", "username", "header", "paths"]
  @schemes ["bearer", "basic", "header"]

  @max_items 16
  @max_hosts 16
  @max_paths 32
  @max_token_bytes 16_384
  @min_lifetime 6 * 60
  @max_lifetime 24 * 60 * 60

  @path ~r/\A\/[^*?#\s]*\*?\z/u
  # The date, the time, the fraction digits and the offset of an RFC 3339 date-time.
  @rfc3339 ~r/\A(\d{4}-\d{2}-\d{2})[Tt](\d{2}:\d{2}:\d{2})(?:\.(\d+))?([Zz]|[+-]\d{2}:\d{2})\z/

  @doc "The causes of a refusal, in the order of the checks."
  @spec causes() :: [cause()]
  def causes, do: @causes

  @doc """
  Checks `credential`, the decoded `credential` member of an adapter's run-credential
  answer, against `entry`, the run's credential entry, at the time `now`, a `DateTime`
  in UTC. Returns `{:ok, %Apiary.Runs.RunCredentialIssue{}}` or `{:error, cause}`, with
  the checks and causes of the module documentation.
  """
  @spec check(map(), map(), DateTime.t()) :: {:ok, t()} | {:error, cause()}
  def check(entry, credential, now) do
    with :ok <- check_now(now),
         :ok <- check_entry(entry),
         :ok <- check_map(credential),
         :ok <- check_members(credential),
         :ok <- check_version(credential),
         :ok <- check_no_placeholders(credential),
         {:ok, token} <- check_token(credential),
         {:ok, items} <- check_apply(credential, entry["apply"]),
         {:ok, expires_at} <- check_expires_at(credential, now) do
      {:ok, %__MODULE__{value: wrap(token), expires_at: expires_at, apply: items}}
    end
  end

  @doc "The token of a checked credential."
  @spec value(t()) :: String.t()
  def value(%__MODULE__{value: value}) when is_function(value, 0), do: value.()

  # A function of no arguments, so that `inspect/2` shows no token, with or without
  # `structs: false`.
  defp wrap(token), do: fn -> token end

  defp check_now(%DateTime{time_zone: "Etc/UTC"}), do: :ok
  defp check_now(_now), do: {:error, :now_invalid}

  # The entry

  defp check_entry(%{"apply" => items} = entry) do
    if only_members?(entry, @entry_members) and placeholders?(Map.get(entry, "placeholders")) and
         is_list(items) and length(items) in 1..@max_items and Enum.all?(items, &entry_item?/1),
       do: :ok,
       else: {:error, :entry_invalid}
  end

  defp check_entry(_entry), do: {:error, :entry_invalid}

  defp placeholders?(nil), do: true
  defp placeholders?(names) when is_list(names), do: Enum.all?(names, &is_binary/1)
  defp placeholders?(_names), do: false

  defp entry_item?(%{"hosts" => hosts, "scheme" => scheme} = item) do
    only_members?(item, @entry_item_members) and strings?(hosts) and hosts != [] and
      scheme in @schemes and optional_string?(item, "username") and
      optional_string?(item, "header") and entry_paths?(Map.get(item, "paths", :absent))
  end

  defp entry_item?(_item), do: false

  defp entry_paths?(:absent), do: true
  defp entry_paths?(paths), do: strings?(paths) and paths != []

  # The answer's shape

  defp check_map(credential) when is_map(credential), do: :ok
  defp check_map(_credential), do: {:error, :answer_invalid}

  defp check_members(credential) do
    items = Map.get(credential, "apply")

    cond do
      not only_members?(credential, @members) -> {:error, :unknown_member}
      is_list(items) and Enum.any?(items, &unknown_item_member?/1) -> {:error, :unknown_member}
      true -> :ok
    end
  end

  defp unknown_item_member?(item) when is_map(item), do: not only_members?(item, @item_members)
  defp unknown_item_member?(_item), do: false

  defp check_version(%{"version" => 1}), do: :ok
  defp check_version(_credential), do: {:error, :version_unsupported}

  defp check_no_placeholders(credential) do
    if Map.has_key?(credential, "placeholders"),
      do: {:error, :placeholders_present},
      else: :ok
  end

  # The token

  defp check_token(%{"token" => token}) when is_binary(token) do
    cond do
      byte_size(token) not in 1..@max_token_bytes -> {:error, :token_size}
      not String.valid?(token) -> {:error, :token_encoding}
      control_character?(token) -> {:error, :token_control_character}
      padded?(token) -> {:error, :token_padded}
      true -> {:ok, token}
    end
  end

  defp check_token(_credential), do: {:error, :token_missing}

  # Called on valid UTF-8 only.
  defp control_character?(<<>>), do: false
  defp control_character?(<<?\t::utf8, rest::binary>>), do: control_character?(rest)

  defp control_character?(<<c::utf8, _rest::binary>>)
       when c < 0x20 or c == 0x7F or c in 0x80..0x9F,
       do: true

  defp control_character?(<<_c::utf8, rest::binary>>), do: control_character?(rest)

  defp padded?(token) do
    String.starts_with?(token, [" ", "\t"]) or String.ends_with?(token, [" ", "\t"])
  end

  # The apply items

  defp check_apply(%{"apply" => items}, entry_items)
       when is_list(items) and items != [] and length(items) <= @max_items do
    Enum.reduce_while(items, {:ok, items}, fn item, acc ->
      case check_item(item, entry_items) do
        :ok -> {:cont, acc}
        error -> {:halt, error}
      end
    end)
  end

  defp check_apply(_credential, _entry_items), do: {:error, :apply_invalid}

  defp check_item(item, entry_items) do
    cond do
      not is_map(item) -> {:error, :apply_item_invalid}
      Map.has_key?(item, "token") -> {:error, :token_in_apply_item}
      not item_shape?(item) -> {:error, :apply_item_invalid}
      true -> inside_entry(item, entry_items)
    end
  end

  defp item_shape?(%{"hosts" => hosts, "scheme" => scheme} = item) do
    distinct_strings?(hosts, @max_hosts) and is_binary(scheme) and
      optional_string?(item, "username") and optional_string?(item, "header") and
      item_paths?(Map.get(item, "paths", :absent))
  end

  defp item_shape?(_item), do: false

  defp item_paths?(:absent), do: true

  defp item_paths?(paths) do
    distinct_strings?(paths, @max_paths) and
      Enum.all?(paths, &(String.valid?(&1) and Regex.match?(@path, &1)))
  end

  defp inside_entry(item, entry_items) do
    same_scheme = Enum.filter(entry_items, &same_scheme?(item, &1))
    with_hosts = Enum.filter(same_scheme, &hosts_inside?(item, &1))

    cond do
      same_scheme == [] -> {:error, :scheme_outside_entry}
      with_hosts == [] -> {:error, :host_outside_entry}
      Enum.any?(with_hosts, &paths_inside?(item, &1)) -> :ok
      true -> {:error, :path_outside_entry}
    end
  end

  defp same_scheme?(item, entry_item) do
    Enum.all?(["scheme", "username", "header"], &(Map.get(item, &1) == Map.get(entry_item, &1)))
  end

  defp hosts_inside?(%{"hosts" => hosts}, %{"hosts" => entry_hosts}),
    do: Enum.all?(hosts, &(&1 in entry_hosts))

  defp paths_inside?(item, %{"paths" => entry_paths}) do
    case item do
      %{"paths" => paths} -> Enum.all?(paths, &path_inside?(&1, entry_paths))
      _no_paths -> false
    end
  end

  defp paths_inside?(_item, _entry_item_without_paths), do: true

  defp path_inside?(path, entry_paths) do
    Enum.any?(entry_paths, fn entry_path ->
      path == entry_path or
        (String.ends_with?(entry_path, "*") and
           String.starts_with?(path, binary_part(entry_path, 0, byte_size(entry_path) - 1)))
    end)
  end

  # The expiry

  defp check_expires_at(%{"expires_at" => expires_at}, now) do
    with {:ok, time} <- parse_time(expires_at) do
      cond do
        DateTime.compare(time, DateTime.add(now, @min_lifetime, :second)) != :gt ->
          {:error, :expires_at_too_soon}

        DateTime.compare(time, DateTime.add(now, @max_lifetime, :second)) == :gt ->
          {:error, :expires_at_too_late}

        true ->
          {:ok, time}
      end
    end
  end

  defp check_expires_at(_credential, _now), do: {:ok, nil}

  # Rebuilds the time with an upper-case `T`, at most 6 fraction digits and `Z` for
  # `z` or `-00:00`, the forms `DateTime.from_iso8601/1` reads.
  defp parse_time(value) when is_binary(value) do
    with [date, time, fraction, offset] <-
           Regex.run(@rfc3339, value, capture: :all_but_first),
         {:ok, parsed, _offset} <-
           DateTime.from_iso8601(date <> "T" <> time <> cut(fraction) <> utc(offset)) do
      {:ok, parsed}
    else
      _invalid -> {:error, :expires_at_invalid}
    end
  end

  defp parse_time(_value), do: {:error, :expires_at_invalid}

  defp cut(""), do: ""
  defp cut(digits), do: "." <> binary_part(digits, 0, min(byte_size(digits), 6))

  defp utc(offset) when offset in ["Z", "z", "-00:00"], do: "Z"
  defp utc(offset), do: offset

  # Helpers

  defp only_members?(map, members), do: Enum.all?(Map.keys(map), &(&1 in members))

  defp optional_string?(map, key), do: is_binary(Map.get(map, key, ""))

  defp strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp strings?(_list), do: false

  defp distinct_strings?(list, max) do
    strings?(list) and list != [] and length(list) <= max and
      length(Enum.uniq(list)) == length(list)
  end
end

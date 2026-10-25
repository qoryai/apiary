defmodule Apiary.Adapters.CallWire do
  # The bodies of Qory Apiary's calls to an adapter, and of the adapter's answers, as the
  # integration contract has them, decoded as `Apiary.Adapters.Wire.decode/1` decodes
  # them: `call?/2` holds a call's body to its schema before it is sent, and `answer/3`
  # reads an answer, `version` 1 and `revision` 1, to its schema. A member a schema does
  # not define is refused.
  #
  #   * `run-credential` (`run-credential.schema.json`): `resources`, refs, each once,
  #     `access` (`read` or `write`) and `purpose`: for `harness`, 1 to 64 resources,
  #     `grant_ref` and the access `read`; for `work`, exactly one resource, the ref of
  #     the target's collection, and `connection_id`, that collection's connection, with
  #     no `grant_ref`.
  #     Its answer is `credential`, the Forager contract's credential document as the
  #     integration contract narrows it (`run-credential-answer.schema.json`): `version` 1,
  #     `token`, 1 to 16,384 bytes with no NUL, carriage return or line feed and no space
  #     or tab at its start or its end, `expires_at` when given, later than `now`, and
  #     `apply`, 1 or more items, each with `hosts` (exact names, none `*.`), `scheme`
  #     (`bearer`, `basic` or `header`), and `username`, `header` and `paths` when given,
  #     no `token`; and no `placeholders`. `{:ok, credential}`, the document as decoded.
  #   * `resolve` (`resolve.schema.json`): `addresses`, 1 to 64, each once, 1 to 2,048
  #     printable ASCII characters. Its answer is `results`, one for each address, in the
  #     call's order: `address`, then `grant_ref` and `resource_ref`, or `covered`,
  #     false, and neither ref. `{:ok, [%{address:, grant_ref:, resource_ref:}
  #     | %{address:, covered: false}]}`.
  #   * `read` (`read.schema.json`): `grant_ref`, `resource_ref`, `path`, a relative path
  #     of 1 to 1,024 characters with no NUL, no empty part and no part `.` or `..`, and
  #     `at`, a version ref. Its answer is `resolved_at`, a version ref, and `content`, UTF-8
  #     of at most 262,144 bytes with no NUL, or `found`, false, and no `content`.
  #     `{:ok, %{resolved_at:, content: content | nil, found: boolean}}`.
  #
  # A ref is 1 to 200 characters with no NUL; a version ref 1 to 255 of `A-Z`, `a-z`,
  # `0-9`, `.`, `_`, `/` and `-`.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  @revision 1
  @max_token 16_384
  @max_content 262_144
  @token ~r/\A[^\x00\r\n \t](?:[^\x00\r\n]*[^\x00\r\n \t])?\z/
  @host ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  @username ~r/\A[^:\s]+\z/u
  @header ~r/\A[A-Za-z0-9-]+\z/
  @apply_path ~r/\A\/[^*?#\s]*\*?\z/u
  @rfc3339 ~r/\A\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})\z/
  @connection_id ~r/\Aac_[0-9a-hjkmnp-tv-z]{16}\z/
  @address ~r/\A[!-~]{1,2048}\z/
  @version_ref ~r/\A[A-Za-z0-9._\/-]{1,255}\z/
  @part "(?:[^/\\x00.][^/\\x00]*|\\.[^/\\x00.][^/\\x00]*|\\.\\.[^/\\x00]+)"
  @document_path Regex.compile!("\\A#{@part}(?:/#{@part})*\\z", "u")

  @doc false
  # call?/2 is whether `body`, a call's body as decoded, with `version` and `time`, is
  # what the schema of the call `path` allows.
  @spec call?(String.t(), map) :: boolean
  def call?(path, %{"version" => 1, "time" => time} = body) do
    time?(time) and call_members?(path, Map.drop(body, ["version", "time"]))
  end

  def call?(_path, _body), do: false

  # A harness credential is read only, under the grant `grant_ref`; a work credential,
  # for the run's target alone, names one resource and the connection of the target's
  # collection.
  defp call_members?("run-credential", %{"purpose" => "harness"} = body) do
    keys?(body, ~w(access grant_ref purpose resources)) and ref?(body["grant_ref"]) and
      run_credential?(body) and body["access"] == "read"
  end

  defp call_members?("run-credential", %{"purpose" => "work"} = body) do
    keys?(body, ~w(access connection_id purpose resources)) and
      connection_id?(body["connection_id"]) and run_credential?(body) and
      length(body["resources"]) == 1
  end

  defp call_members?("resolve", body) do
    keys?(body, ~w(addresses)) and addresses?(body["addresses"])
  end

  defp call_members?("read", body) do
    keys?(body, ~w(at grant_ref path resource_ref)) and ref?(body["grant_ref"]) and
      ref?(body["resource_ref"]) and document_path?(body["path"]) and
      version_ref?(body["at"])
  end

  defp call_members?(_path, _body), do: false

  defp run_credential?(body),
    do: refs?(body["resources"]) and body["access"] in ["read", "write"]

  defp connection_id?(value), do: is_binary(value) and Regex.match?(@connection_id, value)

  defp time?(value), do: match?({:ok, _time}, Apiary.Adapters.Wire.time(value))

  @doc false
  # answer/3 reads `body`, the answer as decoded, to the call `path` whose body was
  # `call`, the call's members as decoded, at `now`. `{:ok, value}` or `:error`.
  @spec answer(String.t(), map, map, DateTime.t()) :: {:ok, term} | :error
  def answer(path, body, call, now \\ DateTime.utc_now())

  def answer(path, %{"version" => 1, "revision" => @revision} = body, call, now) do
    read(path, Map.drop(body, ["version", "revision"]), call, now)
  end

  def answer(_path, _body, _call, _now), do: :error

  defp read("run-credential", %{"credential" => credential} = body, _call, now) do
    if keys?(body, ~w(credential)) and credential?(credential, now),
      do: {:ok, credential},
      else: :error
  end

  defp read("resolve", %{"results" => results} = body, %{"addresses" => addresses}, _now)
       when is_list(results) and length(results) == length(addresses) do
    with true <- keys?(body, ~w(results)),
         read when is_list(read) <- results(results, addresses) do
      {:ok, read}
    else
      _other -> :error
    end
  end

  defp read("read", body, _call, _now) do
    with true <- version_ref?(body["resolved_at"]),
         {:ok, content, found} <- document(body) do
      {:ok, %{resolved_at: body["resolved_at"], content: content, found: found}}
    else
      _other -> :error
    end
  end

  defp read(_path, _body, _call, _now), do: :error

  # The credential document: Forager's `credential.schema.json`, as the integration
  # contract narrows it.
  defp credential?(%{} = credential, now) do
    Enum.all?(Map.keys(credential), &(&1 in ~w(apply expires_at token version))) and
      credential["version"] === 1 and token?(credential["token"]) and
      expires_at?(Map.get(credential, "expires_at", :none), now) and
      apply?(credential["apply"])
  end

  defp credential?(_credential, _now), do: false

  defp token?(token) when is_binary(token),
    do: byte_size(token) <= @max_token and Regex.match?(@token, token)

  defp token?(_token), do: false

  defp expires_at?(:none, _now), do: true

  defp expires_at?(value, now) when is_binary(value) do
    with true <- Regex.match?(@rfc3339, value),
         {:ok, time, _offset} <- DateTime.from_iso8601(String.upcase(value)) do
      DateTime.compare(time, now) == :gt
    else
      _other -> false
    end
  end

  defp expires_at?(_value, _now), do: false

  defp apply?([_ | _] = items), do: Enum.all?(items, &apply_item?/1)
  defp apply?(_items), do: false

  defp apply_item?(%{"hosts" => hosts, "scheme" => scheme} = item) do
    Enum.all?(Map.keys(item), &(&1 in ~w(header hosts paths scheme username))) and
      unique?(hosts, &(is_binary(&1) and Regex.match?(@host, &1))) and
      scheme in ["bearer", "basic", "header"] and
      optional?(item, "username", &Regex.match?(@username, &1)) and
      optional?(item, "header", &Regex.match?(@header, &1)) and
      (not Map.has_key?(item, "paths") or
         unique?(item["paths"], &(is_binary(&1) and Regex.match?(@apply_path, &1))))
  end

  defp apply_item?(_item), do: false

  # A string member that is absent, or matches.
  defp optional?(item, key, match?) do
    case Map.fetch(item, key) do
      :error -> true
      {:ok, value} when is_binary(value) -> match?.(value)
      {:ok, _value} -> false
    end
  end

  # One result for each address, in the call's order.
  defp results(results, addresses) do
    results
    |> Enum.zip(addresses)
    |> Enum.reduce_while([], fn
      {%{"address" => address, "covered" => false} = result, address}, read ->
        if map_size(result) == 2,
          do: {:cont, [%{address: address, covered: false} | read]},
          else: {:halt, :error}

      {%{"address" => address, "grant_ref" => grant, "resource_ref" => resource} = result,
       address},
      read ->
        if map_size(result) == 3 and ref?(grant) and ref?(resource),
          do: {:cont, [%{address: address, grant_ref: grant, resource_ref: resource} | read]},
          else: {:halt, :error}

      _other, _read ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      read -> Enum.reverse(read)
    end
  end

  # A read answer's document: `content`, or `found`, false; not both, not neither.
  defp document(body) do
    case Map.drop(body, ["resolved_at"]) do
      %{"content" => content} = rest when map_size(rest) == 1 and is_binary(content) ->
        if byte_size(content) <= @max_content and not String.contains?(content, <<0>>),
          do: {:ok, content, true},
          else: :error

      %{"found" => false} = rest when map_size(rest) == 1 ->
        {:ok, nil, false}

      _other ->
        :error
    end
  end

  # `body` has exactly `keys`, sorted.
  defp keys?(body, keys), do: Enum.sort(Map.keys(body)) == keys

  @doc false
  # A ref: 1 to 200 characters, none a NUL.
  @spec ref?(term) :: boolean
  def ref?(value) when is_binary(value) do
    String.valid?(value) and (value |> String.to_charlist() |> length()) in 1..200 and
      not String.contains?(value, <<0>>)
  end

  def ref?(_value), do: false

  defp refs?(refs), do: count?(refs, 1..64) and unique?(refs, &ref?/1)

  @doc false
  # An address to resolve: 1 to 2,048 printable ASCII characters.
  @spec address?(term) :: boolean
  def address?(value), do: is_binary(value) and Regex.match?(@address, value)

  defp addresses?(addresses), do: count?(addresses, 1..64) and unique?(addresses, &address?/1)

  @doc false
  # A document's path in a resource: relative, 1 to 1,024 characters, no NUL, no empty
  # part, and no part `.` or `..`.
  @spec document_path?(term) :: boolean
  def document_path?(value) when is_binary(value) do
    String.valid?(value) and (value |> String.to_charlist() |> length()) in 1..1024 and
      Regex.match?(@document_path, value)
  end

  def document_path?(_value), do: false

  @doc false
  # A version ref: 1 to 255 of `A-Z`, `a-z`, `0-9`, `.`, `_`, `/` and `-`.
  @spec version_ref?(term) :: boolean
  def version_ref?(value), do: is_binary(value) and Regex.match?(@version_ref, value)

  defp count?(list, range), do: is_list(list) and length(list) in range

  # A non-empty list, each item once, each as `item?` allows.
  defp unique?([_ | _] = list, item?),
    do: Enum.all?(list, item?) and length(Enum.uniq(list)) == length(list)

  defp unique?(_list, _item?), do: false
end

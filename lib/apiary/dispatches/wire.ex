defmodule Apiary.Dispatches.Wire do
  @moduledoc false

  # The bodies a node pool's starter posts, read as the provisioner contract has them
  # (qoryai/integrations, `contracts/provisioner/v1`). Pure functions: nothing here
  # touches the database or a log, and nothing here puts a value it was sent in an error.
  # Every function answers `:error` for anything it does not accept, never raises on
  # input, and refuses a member its schema does not define, at any depth.
  #
  # The raw body is read as an adapter's is (`Apiary.Adapters.Wire.decode/1`): a JSON
  # object, no member twice at any depth, and a number written with a fraction or an
  # exponent decoded as a float, which no integer field takes (`definitions.schema.json`).
  # A time is the contract's (`Apiary.Adapters.Wire.time/1`), and so is a URL
  # (`Apiary.Adapters.Wire.url?/1`).
  #
  # - `claim/1`, `POST /v1/pools/claim` (`claim.schema.json`): `version` (1), `time`,
  #   `wait_seconds`, an integer from 0 to 25, and, optionally, `pool_id`, a node pool's
  #   id (`np_` and 16 lower-case Crockford base32 characters).
  # - `dispatched/1`, `POST /v1/dispatches/<dispatch_id>/dispatched`
  #   (`dispatched.schema.json`): `version` (1), `time` and, optionally, `external`, which
  #   holds exactly `type` (`$defs/job_system`), `ref`, 1 to 200 characters, and `url`.
  # - `handover/1`, `POST /v1/dispatches/<dispatch_id>/handover`
  #   (`handover.schema.json`): exactly `version` (1) and `time`. What a registration
  #   would carry, its labels among them, the control plane sets from the dispatch, so a
  #   body that carries any of it is refused.
  # - `release/1`, `POST /v1/dispatches/<dispatch_id>/release` (`release.schema.json`):
  #   exactly `version` (1), `time`, `reason`, 1 to 200 characters, and `retry`, a
  #   boolean.
  # - `prebuilt/1`, `POST /v1/dispatches/<dispatch_id>/prebuilt` (`prebuilt.schema.json`):
  #   exactly `version` (1), `time`, `run_id`, a UUID in the canonical lower-case form,
  #   `image`, pinned by its digest (`definitions.schema.json`, `$defs/image`: a lower-case
  #   name of at most 255 characters, `@sha256:` and 64 lower-case hexadecimal digits, at
  #   most 327 characters in all), `size`, an integer from 1 to 2^53 - 1, and
  #   `environment_ref` and `commit`, each 1 to 200 characters.
  #
  # A length in characters is the schema's: Unicode code points. The text a body carries,
  # `ref`, `reason`, `environment_ref` and `commit`, is read as an adapter's text is (`Apiary.Adapters.Wire.text?/3`):
  # valid UTF-8 and no U+0000, which the database cannot keep. Every other string is held
  # to a pattern or a URL's characters, none of which is U+0000.
  #
  # **Bounded first.** Every bound is checked before the work it bounds, and the first
  # that fails refuses: a raw body over 1 MiB, the contract's limit for a request
  # (`refusal.schema.json`, 413), before it is decoded; the count of an object's members,
  # held to the schema's before its keys are compared with the schema's names; a string's
  # bytes, before a pattern is matched or its characters counted (a character is at most
  # 4 bytes of UTF-8). No body is validated against a JSON Schema here: each field is checked
  # explicitly, and no check walks past the first value it refuses.

  alias Apiary.Adapters.Wire, as: AdapterWire

  @pool_id ~r/\Anp_[0-9a-hjkmnp-tv-z]{16}\z/
  @job_system ~r/\A[a-z][a-z0-9 -]{0,39}\z/
  @max_bytes 1024 * 1024
  @max_wait_seconds 25
  @max_ref 200
  @max_reason 200
  @max_commit 200
  @max_size 9_007_199_254_740_991
  @run_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  # The provisioner contract's `$defs/image`, whose name is at most 255 characters: with
  # the digest's 72 after it, at most 327 in all, held before the pattern is matched.
  @image ~r/\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]{1,5})?\/)?[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*@sha256:[0-9a-f]{64}\z/
  @max_image_bytes 327
  # The bytes a string of the contract's may take at most: `pool_id` is ASCII, of a fixed
  # length; `time` is ASCII, `2026-10-15T12:00:00Z`; `type` is ASCII, at most 40; a string
  # of at most 200 characters takes at most 800 bytes (`Apiary.Adapters.Wire.text?/3`).
  @pool_id_bytes 19
  @run_id_bytes 36
  @time_bytes 20
  @max_job_system_bytes 40

  @claim_required ~w(time version wait_seconds)
  @claim_optional ~w(pool_id)
  @dispatched_required ~w(time version)
  @dispatched_optional ~w(external)
  @external_keys ~w(ref type url)
  @handover_keys ~w(time version)
  @release_keys ~w(reason retry time version)
  @prebuilt_keys ~w(commit environment_ref image run_id size time version)

  @type claim :: %{time: DateTime.t(), pool_id: String.t() | nil, wait_seconds: 0..25}
  @type external :: %{type: String.t(), ref: String.t(), url: String.t()}
  @type dispatched :: %{time: DateTime.t(), external: external | nil}
  @type handover :: %{time: DateTime.t()}
  @type release :: %{time: DateTime.t(), reason: String.t(), retry: boolean}
  @type prebuilt :: %{
          time: DateTime.t(),
          run_id: String.t(),
          image: String.t(),
          size: pos_integer,
          environment_ref: String.t(),
          commit: String.t()
        }

  # The raw body as a map of maps, or `:error`, as `Apiary.Adapters.Wire.decode/1` reads
  # it, and `:error`, undecoded, for a body over 1 MiB.
  @doc false
  @spec decode(term) :: {:ok, map} | :error
  def decode(raw) when is_binary(raw) and byte_size(raw) <= @max_bytes,
    do: AdapterWire.decode(raw)

  def decode(_raw), do: :error

  # The largest raw body `decode/1` reads, in bytes.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # The body of a claim, decoded (`decode/1`): `{:ok, claim}` or `:error`.
  @doc false
  @spec claim(term) :: {:ok, claim} | :error
  def claim(%{} = body) do
    with true <- members?(body, @claim_required, @claim_optional),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         wait when is_integer(wait) and wait in 0..@max_wait_seconds <- body["wait_seconds"],
         {:ok, pool_id} <- optional_pool_id(body) do
      {:ok, %{time: time, pool_id: pool_id, wait_seconds: wait}}
    else
      _ -> :error
    end
  end

  def claim(_body), do: :error

  # The body of a dispatched, decoded (`decode/1`): `{:ok, dispatched}` or `:error`.
  @doc false
  @spec dispatched(term) :: {:ok, dispatched} | :error
  def dispatched(%{} = body) do
    with true <- members?(body, @dispatched_required, @dispatched_optional),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         {:ok, external} <- optional_external(body) do
      {:ok, %{time: time, external: external}}
    else
      _ -> :error
    end
  end

  def dispatched(_body), do: :error

  # The body of a handover, decoded (`decode/1`): `{:ok, handover}` or `:error`.
  @doc false
  @spec handover(term) :: {:ok, handover} | :error
  def handover(%{} = body) do
    with true <- members?(body, @handover_keys, []),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]) do
      {:ok, %{time: time}}
    else
      _ -> :error
    end
  end

  def handover(_body), do: :error

  # The body of a release, decoded (`decode/1`): `{:ok, release}` or `:error`.
  @doc false
  @spec release(term) :: {:ok, release} | :error
  def release(%{} = body) do
    with true <- members?(body, @release_keys, []),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         reason when is_binary(reason) <- body["reason"],
         true <- AdapterWire.text?(reason, 1, @max_reason),
         retry when is_boolean(retry) <- body["retry"] do
      {:ok, %{time: time, reason: reason, retry: retry}}
    else
      _ -> :error
    end
  end

  def release(_body), do: :error

  # The body of a prebuilt, decoded (`decode/1`): `{:ok, prebuilt}` or `:error`.
  @doc false
  @spec prebuilt(term) :: {:ok, prebuilt} | :error
  def prebuilt(%{} = body) do
    with true <- members?(body, @prebuilt_keys, []),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         {:ok, run_id} <- run_id(body["run_id"]),
         {:ok, image} <- image(body["image"]),
         size when is_integer(size) and size in 1..@max_size//1 <- body["size"],
         ref when is_binary(ref) <- body["environment_ref"],
         true <- AdapterWire.text?(ref, 1, @max_ref),
         commit when is_binary(commit) <- body["commit"],
         true <- AdapterWire.text?(commit, 1, @max_commit) do
      {:ok,
       %{
         time: time,
         run_id: run_id,
         image: image,
         size: size,
         environment_ref: ref,
         commit: commit
       }}
    else
      _ -> :error
    end
  end

  def prebuilt(_body), do: :error

  # Every member `required` holds is there, and nothing but those and `optional`'s:
  # counted first, so an object of many members is refused before its keys are compared.
  defp members?(body, required, optional) do
    if map_size(body) > length(required) + length(optional) do
      false
    else
      keys = Map.keys(body)
      required -- keys == [] and keys -- (required ++ optional) == []
    end
  end

  defp time(value) when is_binary(value) and byte_size(value) == @time_bytes,
    do: AdapterWire.time(value)

  defp time(_value), do: :error

  defp run_id(value) when is_binary(value) and byte_size(value) == @run_id_bytes do
    if Regex.match?(@run_id, value), do: {:ok, value}, else: :error
  end

  defp run_id(_value), do: :error

  defp image(value) when is_binary(value) and byte_size(value) <= @max_image_bytes do
    if Regex.match?(@image, value), do: {:ok, value}, else: :error
  end

  defp image(_value), do: :error

  defp optional_pool_id(%{"pool_id" => pool_id})
       when is_binary(pool_id) and byte_size(pool_id) == @pool_id_bytes do
    if Regex.match?(@pool_id, pool_id), do: {:ok, pool_id}, else: :error
  end

  defp optional_pool_id(%{"pool_id" => _pool_id}), do: :error

  defp optional_pool_id(_body), do: {:ok, nil}

  defp optional_external(%{"external" => %{} = external}) do
    with true <- members?(external, @external_keys, []),
         type when is_binary(type) and byte_size(type) <= @max_job_system_bytes <-
           external["type"],
         true <- Regex.match?(@job_system, type),
         ref when is_binary(ref) <- external["ref"],
         true <- AdapterWire.text?(ref, 1, @max_ref),
         url when is_binary(url) <- external["url"],
         true <- AdapterWire.url?(url) do
      {:ok, %{type: type, ref: ref, url: url}}
    else
      _ -> :error
    end
  end

  defp optional_external(%{"external" => _other}), do: :error
  defp optional_external(_body), do: {:ok, nil}
end

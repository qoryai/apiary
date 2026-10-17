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
  #
  # A length in characters is the schema's: Unicode code points.

  alias Apiary.Adapters.Wire, as: AdapterWire

  @pool_id ~r/\Anp_[0-9a-hjkmnp-tv-z]{16}\z/
  @job_system ~r/\A[a-z][a-z0-9 -]{0,39}\z/
  @max_wait_seconds 25
  @max_ref 200
  @max_reason 200

  @claim_required ~w(time version wait_seconds)
  @claim_optional ~w(pool_id)
  @dispatched_required ~w(time version)
  @dispatched_optional ~w(external)
  @external_keys ~w(ref type url)
  @handover_keys ~w(time version)
  @release_keys ~w(reason retry time version)

  @type claim :: %{time: DateTime.t(), pool_id: String.t() | nil, wait_seconds: 0..25}
  @type external :: %{type: String.t(), ref: String.t(), url: String.t()}
  @type dispatched :: %{time: DateTime.t(), external: external | nil}
  @type handover :: %{time: DateTime.t()}
  @type release :: %{time: DateTime.t(), reason: String.t(), retry: boolean}

  # The raw body as a map of maps, or `:error`, as `Apiary.Adapters.Wire.decode/1` reads
  # it.
  @doc false
  @spec decode(term) :: {:ok, map} | :error
  defdelegate decode(raw), to: AdapterWire

  # The body of a claim, decoded (`decode/1`): `{:ok, claim}` or `:error`.
  @doc false
  @spec claim(term) :: {:ok, claim} | :error
  def claim(%{} = body) do
    with true <- members?(body, @claim_required, @claim_optional),
         true <- body["version"] === 1,
         {:ok, time} <- AdapterWire.time(body["time"]),
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
         {:ok, time} <- AdapterWire.time(body["time"]),
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
         {:ok, time} <- AdapterWire.time(body["time"]) do
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
         {:ok, time} <- AdapterWire.time(body["time"]),
         reason when is_binary(reason) <- body["reason"],
         true <- characters(reason) in 1..@max_reason,
         retry when is_boolean(retry) <- body["retry"] do
      {:ok, %{time: time, reason: reason, retry: retry}}
    else
      _ -> :error
    end
  end

  def release(_body), do: :error

  # Every member `required` holds is there, and nothing but those and `optional`'s.
  defp members?(body, required, optional) do
    keys = Map.keys(body)
    required -- keys == [] and keys -- (required ++ optional) == []
  end

  defp optional_pool_id(%{"pool_id" => pool_id}) do
    if is_binary(pool_id) and Regex.match?(@pool_id, pool_id), do: {:ok, pool_id}, else: :error
  end

  defp optional_pool_id(_body), do: {:ok, nil}

  defp optional_external(%{"external" => %{} = external}) do
    with true <- Enum.sort(Map.keys(external)) == @external_keys,
         type when is_binary(type) <- external["type"],
         true <- Regex.match?(@job_system, type),
         ref when is_binary(ref) <- external["ref"],
         true <- characters(ref) in 1..@max_ref,
         url when is_binary(url) <- external["url"],
         true <- AdapterWire.url?(url) do
      {:ok, %{type: type, ref: ref, url: url}}
    else
      _ -> :error
    end
  end

  defp optional_external(%{"external" => _other}), do: :error
  defp optional_external(_body), do: {:ok, nil}

  # A string's length as JSON Schema counts it: in code points.
  defp characters(string), do: string |> String.codepoints() |> length()
end

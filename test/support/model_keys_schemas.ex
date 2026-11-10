defmodule Apiary.ModelKeysSchemas do
  @moduledoc """
  Validates a report of a run's model keys, and its answer, against the Forager
  contract's `model-keys-report.schema.json` and `model-keys-answer.schema.json`, as the
  contract's draft has them: a copy kept here until Forager publishes the files.

  Replace this module when the files are vendored under `priv/contract/`
  (`.forager-contract-ref`): call `Apiary.ForagerSchemas.validate/2` with the same file
  names, and delete this module. Every other schema is read from `priv/contract/`.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/forager/v1/"

  # The draft's `$defs/key_state`, shared by both schemas.
  @key_state %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["credential", "window", "status", "source", "observed_at"],
    "properties" => %{
      "credential" => %{"$ref" => "run-configuration.schema.json#/$defs/credential_name"},
      "window" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9_]{0,63}$"},
      "status" => %{"enum" => ["allowed", "allowed_warning", "rejected"]},
      "resets_at" => %{"type" => "string", "format" => "date-time"},
      "utilization" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
      "cooldown_until" => %{"type" => "string", "format" => "date-time"},
      "source" => %{"enum" => ["provider", "schedule", "pause_for"]},
      "observed_at" => %{"type" => "string", "format" => "date-time"}
    }
  }

  @schemas %{
    "model-keys-report.schema.json" => %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => @base <> "model-keys-report.schema.json",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["version", "run_id", "time", "keys"],
      "properties" => %{
        "version" => %{"const" => 1},
        "run_id" => %{
          "type" => "string",
          "pattern" => "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "time" => %{"type" => "string", "format" => "date-time"},
        "keys" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/key_state"}}
      },
      "$defs" => %{"key_state" => @key_state}
    },
    "model-keys-answer.schema.json" => %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => @base <> "model-keys-answer.schema.json",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["version", "keys"],
      "properties" => %{
        "version" => %{"const" => 1},
        "keys" => %{
          "type" => "array",
          "items" => %{"$ref" => "model-keys-report.schema.json#/$defs/key_state"}
        }
      }
    }
  }

  @doc """
  validate/2 validates `document`, bytes or decoded JSON, against `file`,
  `"model-keys-report.schema.json"` or `"model-keys-answer.schema.json"`: `:ok`, or
  `{:error, error}`.
  """
  @spec validate(String.t(), binary | map) :: :ok | {:error, term}
  def validate(file, document) when is_binary(document),
    do: validate(file, Jason.decode!(document))

  def validate(file, document) when is_map_key(@schemas, file) do
    root = JSV.build!(%{"$ref" => @base <> file}, resolver: __MODULE__, formats: true)

    case JSV.validate(document, root, cast: false) do
      {:ok, _document} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl JSV.Resolver
  def resolve(@base <> file = url, opts) do
    case Map.fetch(@schemas, file) do
      {:ok, schema} -> {:ok, schema}
      :error -> Apiary.ForagerSchemas.resolve(url, opts)
    end
  end

  def resolve(url, opts), do: Apiary.ForagerSchemas.resolve(url, opts)
end

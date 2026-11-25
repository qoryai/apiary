defmodule Apiary.Artifacts.HarnessPrimitives do
  # HarnessPrimitives resolves the `$id` of qory's primitives of the harness contracts,
  # `https://qory.dev/contracts/harness/v1/primitives.schema.json`, to the copy at
  # `priv/contract/harness/v1/primitives.schema.json`, pinned with `process.schema.json` in
  # the `.contract-ref` beside it. The schema of a custom structured type may refer to a
  # primitive there, such as `…/primitives.schema.json#/$defs/reference`, and
  # `Apiary.Artifacts.CustomSchema` builds it with this resolver first. Any other address
  # goes on to the next resolver. The copy is read when this module is compiled, so a
  # build fetches nothing over the network. Its patterns get
  # `Apiary.Kinds.Pattern.end_only/1`, as the patterns of the type's schema do.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  @behaviour JSV.Resolver

  @path Path.expand("../../../priv/contract/harness/v1/primitives.schema.json", __DIR__)
  @external_resource @path

  # The copy's patterns are outside the estimate of `Apiary.Kinds.PatternMemory`, which
  # counts those of the type's schema. The copy is fixed, and `PatternMemory.schema/1`
  # puts its patterns at 50,580 bytes against the 16 MiB budget, so this is accepted.
  @schema @path |> File.read!() |> Jason.decode!() |> Apiary.Kinds.Pattern.end_only()
  @id Map.fetch!(@schema, "$id")

  @impl JSV.Resolver
  def resolve(@id, _opts), do: {:ok, @schema}
  def resolve(url, _opts), do: {:error, {:not_primitives, url}}
end

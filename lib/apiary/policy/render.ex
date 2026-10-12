defmodule Apiary.Policy.Render do
  @moduledoc """
  The run configuration document of an effective policy, as the bytes that are stored,
  digested and served.

  Deterministic: members in a fixed order, lists sorted by `Apiary.Policy.Resolution`, no
  insignificant whitespace, so the same rules give the same bytes and the same digest.
  `allow` is always written, empty when nothing is allowed; `deny` and `paths` only when
  they hold something, so a policy without a deny renders the bytes it always did. The
  document selects no credential: the contract's `credentials` member is never written.
  """

  alias Apiary.Policy.Effective

  @version 1

  @doc "The document's bytes."
  @spec document(Effective.t()) :: binary
  def document(%Effective{} = effective) do
    Jason.encode!(
      ordered(version: @version, security_policy: security_policy(effective)),
      escape: :json
    )
  end

  @doc """
  The document of no policy, `{"version":1}`, encoded as `document/1` encodes one: what a
  run is given where its workspace serves no run configuration. Always the same bytes, so
  always the same digest.
  """
  @spec no_policy_document() :: binary
  def no_policy_document, do: Jason.encode!(ordered(version: @version), escape: :json)

  @doc "The digest of a document's bytes: `sha256=` and lower-case hex."
  @spec digest(binary) :: String.t()
  def digest(document) when is_binary(document) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, document), case: :lower)
  end

  @doc "The policy document alone, as decoded JSON would be, in the document's order."
  def security_policy(%Effective{} = effective) do
    egress =
      [mode: effective.mode, allow: effective.allow] ++
        if(effective.deny != [], do: [deny: effective.deny], else: []) ++
        if(map_size(effective.paths) > 0,
          do: [paths: effective.paths |> Enum.sort() |> ordered()],
          else: []
        )

    ordered(version: @version, egress: ordered(egress))
  end

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)
end

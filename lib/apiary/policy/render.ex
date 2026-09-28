defmodule Apiary.Policy.Render do
  @moduledoc """
  The run configuration document of an effective policy, as the bytes that are stored,
  digested and served.

  Deterministic: members in a fixed order, lists sorted by `Apiary.Policy.Resolution`, no
  insignificant whitespace, so the same rules give the same bytes and the same digest.
  `allow` is always written, empty when nothing is allowed; `deny`, `paths` and
  `credentials` only when they hold something, so a policy without a deny renders the
  bytes it always did.
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

    credentials =
      for credential <- effective.credentials do
        ordered(
          [name: credential.name] ++
            if(credential[:argument], do: [argument: credential.argument], else: [])
        )
      end

    ordered(
      [version: @version, egress: ordered(egress)] ++
        if(credentials != [], do: [credentials: credentials], else: [])
    )
  end

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)
end

defmodule Apiary.Policy.Render do
  @moduledoc """
  The run configuration document of an effective policy, as the bytes that are stored,
  digested and served.

  Deterministic: members in a fixed order, lists sorted by `Apiary.Policy.Resolution`, no
  insignificant whitespace, so the same rules give the same bytes and the same digest.
  `allow` is always written, empty when nothing is allowed; `allow_first`, `deny` and
  `paths` only when they have an entry, so a policy without an integration's host or a
  deny renders the bytes it always did. The document selects no credential: a policy
  never writes the contract's `credentials` member.
  """

  # With the features `factory` and `secrets`, which the documentation leaves out:
  # `credentials` and `model_credential` are written in the document composed for a run
  # that its claim set a model provider for (`Apiary.Policy.ComposedConfiguration`,
  # `Apiary.Runs.ProviderCredential`), never in a policy's.

  alias Apiary.Policy.Effective

  @version 1

  # The most entries the field `egress.allow_first` takes.
  @allow_first_max 64

  @doc """
  render/1 is the document of `effective` (`document/1`) and the hosts of its
  `allow_first` (`Apiary.Policy.Effective`): `{:ok, document, allow_first}`, or
  `{:error, {:allow_first_too_long, count}}` when there are more than 64 hosts, the most
  entries the field `egress.allow_first` takes.
  """
  @spec render(Effective.t()) ::
          {:ok, binary, [String.t()]} | {:error, {:allow_first_too_long, pos_integer}}
  def render(%Effective{allow_first: hosts} = effective) do
    case length(hosts) do
      count when count > @allow_first_max -> {:error, {:allow_first_too_long, count}}
      _count -> {:ok, document(effective), hosts}
    end
  end

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

    ordered(version: @version, egress: ordered(allow_first(egress, effective.allow_first)))
  end

  @doc """
  allow_first/2 is the one place that writes `egress.allow_first`: it takes the members
  of `egress`, in the document's order, and the hosts of `Apiary.Policy.Effective`'s
  `allow_first`, and returns the members to write. The hosts go right after `allow`,
  which `security_policy/1` always writes, in the schema's order. An empty list adds no
  member.
  """
  @spec allow_first(keyword, [String.t()]) :: keyword
  def allow_first(egress, []) when is_list(egress), do: egress

  def allow_first(egress, hosts) when is_list(egress) and is_list(hosts) do
    Enum.flat_map(egress, fn
      {:allow, _allow} = allow -> [allow, {:allow_first, hosts}]
      member -> [member]
    end)
  end

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)
end

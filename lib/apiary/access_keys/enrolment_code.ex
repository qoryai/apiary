defmodule Apiary.AccessKeys.EnrolmentCode do
  # The prefix of each kind's code, the one place the prefixes are written: the codes made,
  # the check at enrolment that a code is its node's kind's, the log filter and the tests
  # read them from here. The moduledoc names a node's, a node pool's and a gateway's alone.
  @prefixes %{
    node: "qecn_",
    pool: "qecp_",
    gateway: "qecg_",
    adapter: "qeci_",
    diagnostics: "qecd_"
  }
  # The prefix of a run code (`Apiary.Runs.RunCode`), which enrols no key and belongs to no
  # node: a claim answers with it, and enrolment redeems it for the run's run key.
  @run_prefix "qecr_"

  @moduledoc """
  An enrolment code of a node: what an owner or an admin gives a machine so that it
  enrols an access key for that node or node pool, single use and valid for a short while
  (`Apiary.AccessKeys.create_enrolment_code/3`).

  A code is the prefix of its node's kind (`prefix/1`), `#{@prefixes.node}` for a node,
  `#{@prefixes.pool}` for a node pool and `#{@prefixes.gateway}` for a gateway, then 26
  Crockford base32 characters, 130 random bits, in upper case (`generate/1`). A person
  may type it in either case and in groups: `normalise/1` reads the prefix in lower case
  and the rest in upper case, `I` and `L` as `1`, `O` as `0`, and drops hyphens; `U` and
  every character outside the alphabet are refused. The server's fingerprints that follow
  the code on the wire, after a `.`, are not part of what is hashed and stored; the whole
  code before them, its prefix with it, is (`hash/1`).

  The row keeps the code's SHA-256 only (`hash/1`), never the code: with 130 random bits a
  fast hash is enough. It carries the settings the key it brings gets, the stored-secrets
  flag (`allow_secrets`) and a label to start from (`label_hint`), when it expires, and
  when it was used, by which key id and public key, or cancelled. Its integrity code
  (`Apiary.Integrity`) covers `integrity_fields/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "An enrolment code of a node."
  @type t :: %__MODULE__{}

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @integrity_kind "access_key_enrolment_code"
  @integrity_version 1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_key_enrolment_codes" do
    field :code_sha256, :binary, redact: true
    field :allow_secrets, :boolean, default: false
    field :label_hint, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :used_by_key_id, :string
    field :public_key, :binary
    field :cancelled_at, :utc_datetime_usec
    field :integrity_code, :binary, redact: true
    field :integrity_key_id, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :node, Apiary.Nodes.Node
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  settings_changeset/2 is the changeset of a new code's settings: the stored-secrets flag,
  off unless set, and a label hint, empty or a name Forager would send
  (`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`).
  """
  @spec settings_changeset(t, map) :: Ecto.Changeset.t()
  def settings_changeset(%__MODULE__{} = code, attrs) do
    code
    |> cast(attrs, [:allow_secrets, :label_hint])
    |> validate_format(:label_hint, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/)
  end

  @doc "prefix/1 is the prefix of a code of a node of `kind`."
  @spec prefix(Apiary.Nodes.Node.kind()) :: String.t()
  def prefix(kind), do: Map.fetch!(@prefixes, kind)

  # Every kind's prefix, by kind: for the log filter and the tests, which read them from
  # here alone.
  @doc false
  def prefixes, do: @prefixes

  @doc """
  of_kind?/2 says whether `code` carries the prefix of `kind` (`prefix/1`), compared as
  written.
  """
  @spec of_kind?(String.t(), Apiary.Nodes.Node.kind()) :: boolean
  def of_kind?(code, kind) when is_binary(code), do: String.starts_with?(code, prefix(kind))

  @doc """
  prefixed?/1 says whether `code` carries the prefix of a kind of node (`prefix/1`),
  compared as written.
  """
  @spec prefixed?(String.t()) :: boolean
  def prefixed?(code) when is_binary(code),
    do: Enum.any?(Map.keys(@prefixes), &of_kind?(code, &1))

  # run_prefix/0 is the prefix of a run code (`Apiary.Runs.RunCode`). `prefixed?/1`,
  # `normalise/1` and the node kinds' prefixes leave it out.
  @doc false
  @spec run_prefix() :: String.t()
  def run_prefix, do: @run_prefix

  # run_code?/1 says whether `code` has the prefix of a run code, compared as written.
  @doc false
  @spec run_code?(String.t()) :: boolean
  def run_code?(code) when is_binary(code), do: String.starts_with?(code, @run_prefix)

  @doc """
  generate/1 is a fresh code of a node of `kind`: the kind's prefix (`prefix/1`) and 26
  upper-case Crockford base32 characters, 130 random bits.
  """
  # `generate(:run)` is a fresh run code, with the prefix `run_prefix/0`.
  @spec generate(Apiary.Nodes.Node.kind() | :run) :: String.t()
  def generate(:run), do: @run_prefix <> random_body()
  def generate(kind), do: prefix(kind) <> random_body()

  defp random_body do
    <<random::bitstring-size(130), _rest::bitstring>> = :crypto.strong_rand_bytes(17)
    for(<<chunk::5 <- random>>, into: "", do: <<Enum.at(@alphabet, chunk)>>)
  end

  @doc """
  normalise/1 reads a code as a person may type it: the prefix of a kind of node
  (`prefix/1`) in either case, then the 26 characters in either case and in groups, `I`
  and `L` read as `1`, `O` as `0`, hyphens dropped; the case of ASCII letters alone is
  changed, so a character outside ASCII is refused. `{:ok, code}` in the form
  `generate/1` makes, the prefix in lower case, or `:error` for anything else, `U`
  included.

  It is for a page, where a person types a code. The enrolment endpoint does not use it:
  `qory` sends the code normalised, and the wire refuses a code in any other form, by the
  contract's pattern, so what a proof signed is the code as sent.
  """
  @spec normalise(term) :: {:ok, String.t()} | :error
  def normalise(value) when is_binary(value) do
    with {prefix, rest} <- split_prefix(value),
         body = rest |> String.replace("-", "") |> String.upcase(:ascii),
         body = body |> String.replace(["I", "L"], "1") |> String.replace("O", "0"),
         26 <- byte_size(body),
         true <- alphabet?(body) do
      {:ok, prefix <> body}
    else
      _ -> :error
    end
  end

  def normalise(_value), do: :error

  # Byte by byte: the alphabet is ASCII, so a byte outside it, the first byte of a
  # character that takes more than one, or bytes that are not UTF-8 at all, is refused.
  defp alphabet?(body),
    do: for(<<byte <- body>>, reduce: true, do: (ok -> ok and byte in @alphabet))

  # The prefix of a kind of node a typed code starts with, in either case, and the rest.
  defp split_prefix(value) do
    Enum.find_value(Map.values(@prefixes), :error, fn prefix ->
      size = byte_size(prefix)

      case value do
        <<typed::binary-size(^size), rest::binary>> ->
          if String.downcase(typed, :ascii) == prefix, do: {prefix, rest}

        _shorter ->
          nil
      end
    end)
  end

  @doc "hash/1 is the SHA-256 of a code in its normal form (`normalise/1`), as stored."
  @spec hash(String.t()) :: <<_::256>>
  def hash(code) when is_binary(code), do: :crypto.hash(:sha256, code)

  @doc """
  outstanding?/2 says whether `code` may still be used at `now`: neither used, nor
  cancelled, nor expired.
  """
  @spec outstanding?(t, DateTime.t()) :: boolean
  def outstanding?(%__MODULE__{} = code, %DateTime{} = now) do
    is_nil(code.used_at) and is_nil(code.cancelled_at) and
      DateTime.compare(code.expires_at, now) == :gt
  end

  @doc """
  integrity_fields/1 is what a code's integrity code covers, in its fixed order:
  everything but its timestamps.
  """
  @spec integrity_fields(t) :: Apiary.Integrity.fields()
  def integrity_fields(%__MODULE__{} = code) do
    [
      id: code.id,
      organisation_id: code.organisation_id,
      workspace_id: code.workspace_id,
      node_id: code.node_id,
      code_sha256: code.code_sha256,
      allow_secrets: code.allow_secrets,
      label_hint: code.label_hint,
      expires_at: code.expires_at,
      used_at: code.used_at,
      used_by_key_id: code.used_by_key_id,
      public_key: code.public_key,
      cancelled_at: code.cancelled_at,
      created_by_id: code.created_by_id
    ]
  end

  @doc "put_integrity/1 sets a code's integrity code from `changeset` as it will be written."
  @spec put_integrity(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def put_integrity(%Ecto.Changeset{} = changeset) do
    {key_id, code} =
      Apiary.Integrity.code(
        @integrity_kind,
        @integrity_version,
        changeset |> apply_changes() |> integrity_fields()
      )

    changeset
    |> put_change(:integrity_key_id, key_id)
    |> put_change(:integrity_code, code)
  end

  @doc """
  verify_integrity/1 checks a code's integrity code against its row: `:ok`, or
  `{:error, :mismatch | :unknown_key}`.
  """
  @spec verify_integrity(t) :: :ok | {:error, :mismatch | :unknown_key}
  def verify_integrity(%__MODULE__{} = code) do
    Apiary.Integrity.verify(
      @integrity_kind,
      @integrity_version,
      integrity_fields(code),
      code.integrity_key_id,
      code.integrity_code
    )
  end
end
